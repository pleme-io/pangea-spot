# frozen_string_literal: true

require 'pangea/architectures/spot/types'
require 'pangea/architectures/spot/k8s_jit_node_pool'
require 'pangea/architectures/spot/breathability_helpers'

module Pangea
  module Architectures
    module Spot
      # ZotJitService — breathable OCI registry.
      #
      # Same JIT five-dimension shape as AtticJitService, differing in:
      #   - port: 5000 (zot default) instead of 8080
      #   - state: S3 backing via zot's `s3` storage driver (manifests +
      #     layers live in the bucket; zot runs stateless pulling
      #     read/write from S3)
      #   - auth: optional htpasswd_secret_arn is carried through as an
      #     instance tag so user_data on the AMI can fetch it from
      #     Secrets Manager and configure zot's auth block
      #   - TLS: optional acm_cert_arn terminates TLS at the NLB. When
      #     absent, the listener is plain TCP:5000 (suitable for
      #     in-VPC-only use). NLB-side TLS termination (not a full
      #     TLS-between-client-and-zot chain) — for client-to-registry
      #     TLS with SNI routing, use an ALB instead.
      #
      # Returns:
      #   { node_pool_result:, nlb:, target_group:, listener:,
      #     registry_bucket:, fqdn:, quiescent_scale_policy:, quiescent_alarm:,
      #     tls_enabled: Bool }
      module ZotJitService
        def self.build(synth, config = {})
          config = Types::ZotJitServiceConfig.new(config).to_h

          synth.extend(Pangea::Resources::AWS) unless synth.respond_to?(:aws_lb)

          name = config[:name]
          tags = config[:tags] || {}
          port = config[:service_port]
          tls_enabled = !(config[:acm_cert_arn].nil? || config[:acm_cert_arn].to_s.empty?)

          # ── State bucket ──────────────────────────────────────────────
          bucket_name = config[:s3_bucket_name] || "#{name}-zot-registry"
          registry_bucket = BreathabilityHelpers.emit_state_bucket(
            synth,
            resource_name: "#{name}-zot",
            bucket_name: bucket_name,
            tags: tags.merge(Service: 'zot'),
          )

          # ── Breathable node pool ──────────────────────────────────────
          # Propagate the htpasswd secret ARN + the S3 bucket name as
          # instance tags. The AMI's user_data / systemd unit reads these
          # tags at boot to configure zot's storage + auth sections.
          extra_tags = {
            Service: 'zot',
            ZotBucket: bucket_name,
          }
          if config[:htpasswd_secret_arn]
            extra_tags[:ZotHtpasswdSecretArn] = config[:htpasswd_secret_arn]
          end

          node_pool_result = K8sJitNodePool.build(synth, {
            name: "#{name}-zot",
            profile: config[:profile],
            image_id: config[:image_id],
            instance_profile_arn: config[:instance_profile_arn],
            security_group_ids: config[:security_group_ids],
            subnet_ids: config[:subnet_ids],
            key_name: config[:key_name],
            user_data_base64: config[:user_data_base64],
            min_size: config[:min_size],
            max_size: config[:max_size],
            desired_capacity: config[:desired_capacity],
            node_labels: { 'service' => 'zot' },
            node_taints: [],
            alert_layer: config[:alert_layer] || {},
            tags: tags.merge(extra_tags),
          })

          asg_name = "#{name}-zot-asg"

          # ── NLB + listener + autoscaling attachment ───────────────────
          nlb = synth.aws_lb(:"#{name}-zot-nlb", {
            name: "#{name}-zot-nlb",
            internal: false,
            load_balancer_type: 'network',
            subnets: config[:subnet_ids],
            tags: tags.merge(Name: "#{name}-zot-nlb", Service: 'zot'),
          })

          tg_protocol = tls_enabled ? 'TCP' : 'TCP'
          tg = synth.aws_lb_target_group(:"#{name}-zot-tg", {
            name: "#{name}-zot-tg",
            port: port,
            protocol: tg_protocol,
            deregistration_delay: '30',
            health_check: {
              protocol: 'TCP',
              port: port.to_s,
              healthy_threshold: 2,
              unhealthy_threshold: 2,
              interval: 30,
            },
            tags: tags.merge(Name: "#{name}-zot-tg", Service: 'zot'),
          })

          listener_attrs = {
            load_balancer_arn: nlb.arn,
            default_action: [{ type: 'forward', target_group_arn: tg.arn }],
          }
          if tls_enabled
            listener_attrs[:port] = 443
            listener_attrs[:protocol] = 'TLS'
            listener_attrs[:certificate_arn] = config[:acm_cert_arn]
            listener_attrs[:ssl_policy] = 'ELBSecurityPolicy-TLS13-1-2-2021-06'
          else
            listener_attrs[:port] = port
            listener_attrs[:protocol] = 'TCP'
          end
          listener = synth.aws_lb_listener(:"#{name}-zot-listener", listener_attrs)

          synth.aws_autoscaling_attachment(:"#{name}-zot-asg-tg", {
            autoscaling_group_name: asg_name,
            lb_target_group_arn: tg.arn,
          })

          # ── Stable CNAME → NLB ────────────────────────────────────────
          fqdn = "#{name}.#{config[:domain]}"
          synth.aws_route53_record(:"#{name}-zot-cname", {
            zone_id: config[:public_zone_id],
            name: fqdn,
            type: 'CNAME',
            ttl: 60,
            records: [nlb.ref(:dns_name)],
          })

          # ── Scale-to-zero quiescent backstop ──────────────────────────
          quiescent = BreathabilityHelpers.emit_quiescent_scale_to_zero(
            synth,
            name: "#{name}-zot",
            asg_name: asg_name,
            idle_threshold_secs: config[:idle_threshold_secs],
            metric_namespace: 'Pleme/ZotRegistry',
            tags: tags.merge(Service: 'zot'),
          )

          {
            node_pool_result: node_pool_result,
            nlb: nlb,
            target_group: tg,
            listener: listener,
            registry_bucket: registry_bucket,
            fqdn: fqdn,
            quiescent_scale_policy: quiescent[:scale_policy],
            quiescent_alarm: quiescent[:alarm],
            tls_enabled: tls_enabled,
          }
        end
      end
    end
  end
end
