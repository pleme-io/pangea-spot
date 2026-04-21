# frozen_string_literal: true

require 'pangea/architectures/spot/types'
require 'pangea/architectures/spot/k8s_jit_node_pool'
require 'pangea/architectures/spot/breathability_helpers'

module Pangea
  module Architectures
    module Spot
      # AtticJitService — breathable Nix binary cache.
      #
      # Looks persistent from outside (stable CNAME at {name}.{domain}
      # fronted by an NLB) but the backing fleet breathes: scale-to-zero
      # when idle, wake on first request. State is fully externalized to
      # S3 (Attic stores chunked cache content in the bucket), so spot
      # reclaims are harmless — a new instance pulls from S3 on boot and
      # resumes serving.
      #
      # Composition (JIT five-dimension):
      #   - auction substrate  → K8sJitNodePool with small profile
      #                          (default :karpenter_general, min=0, max=2)
      #   - breathability       → idle alarm + ExactCapacity=0 policy
      #                          + first-request wake (warm-up latency
      #                          documented — first pull after sleep
      #                          takes ~45-90s for the ASG to launch +
      #                          Attic daemon to boot)
      #   - state externalization → S3 bucket (versioned, SSE-AES256,
      #                          public access blocked)
      #   - interruption policy → inherited from K8sJitNodePool
      #                          (:drain_k8s_node emits EB rule; with no
      #                          Lambda supplied, rule is observability
      #                          only — Attic survives interruption
      #                          trivially since state is in S3)
      #   - substrate provider  → AWS ASG (via MixedInstancesAsg
      #                          inside K8sJitNodePool)
      #
      # Caller supplies the AMI (typically a NixOS image baked with the
      # attic-server package pre-installed and configured to read the
      # S3 bucket name from instance metadata tags). This architecture
      # doesn't render user_data; the AMI knows how to find the bucket
      # from the `AtticBucket` instance tag.
      #
      # Returns:
      #   { node_pool_result:, nlb:, target_group:, listener:,
      #     cache_bucket:, fqdn:, quiescent_scale_policy:, quiescent_alarm: }
      module AtticJitService
        def self.build(synth, config = {})
          config = Types::AtticJitServiceConfig.new(config).to_h

          synth.extend(Pangea::Resources::AWS) unless synth.respond_to?(:aws_lb)

          name = config[:name]
          tags = config[:tags] || {}
          port = config[:service_port]

          # ── State bucket ──────────────────────────────────────────────
          bucket_name = config[:s3_bucket_name] || "#{name}-attic-cache"
          cache_bucket = BreathabilityHelpers.emit_state_bucket(
            synth,
            resource_name: "#{name}-attic",
            bucket_name: bucket_name,
            tags: tags.merge(Service: 'attic'),
          )

          # ── Breathable node pool ──────────────────────────────────────
          node_pool_result = K8sJitNodePool.build(synth, {
            name: "#{name}-attic",
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
            node_labels: { 'service' => 'attic' },
            node_taints: [],
            alert_layer: config[:alert_layer] || {},
            tags: tags.merge(
              Service: 'attic',
              AtticBucket: bucket_name,
            ),
          })

          asg_name = "#{name}-attic-asg"

          # ── NLB + listener + autoscaling attachment ───────────────────
          nlb = synth.aws_lb(:"#{name}-attic-nlb", {
            name: "#{name}-attic-nlb",
            internal: false,
            load_balancer_type: 'network',
            subnets: config[:subnet_ids],
            tags: tags.merge(Name: "#{name}-attic-nlb", Service: 'attic'),
          })

          tg = synth.aws_lb_target_group(:"#{name}-attic-tg", {
            name: "#{name}-attic-tg",
            port: port,
            protocol: 'TCP',
            vpc_id: nil, # caller-supplied via composition or cross-stack output
            deregistration_delay: '30',
            health_check: {
              protocol: 'TCP',
              port: port.to_s,
              healthy_threshold: 2,
              unhealthy_threshold: 2,
              interval: 30,
            },
            tags: tags.merge(Name: "#{name}-attic-tg", Service: 'attic'),
          })

          listener = synth.aws_lb_listener(:"#{name}-attic-listener", {
            load_balancer_arn: nlb.arn,
            port: port,
            protocol: 'TCP',
            default_action: [{ type: 'forward', target_group_arn: tg.arn }],
          })

          synth.aws_autoscaling_attachment(:"#{name}-attic-asg-tg", {
            autoscaling_group_name: asg_name,
            lb_target_group_arn: tg.arn,
          })

          # ── Stable CNAME → NLB ────────────────────────────────────────
          fqdn = "#{name}.#{config[:domain]}"
          synth.aws_route53_record(:"#{name}-attic-cname", {
            zone_id: config[:public_zone_id],
            name: fqdn,
            type: 'CNAME',
            ttl: 60,
            records: [nlb.ref(:dns_name)],
          })

          # ── Scale-to-zero quiescent backstop ──────────────────────────
          quiescent = BreathabilityHelpers.emit_quiescent_scale_to_zero(
            synth,
            name: "#{name}-attic",
            asg_name: asg_name,
            idle_threshold_secs: config[:idle_threshold_secs],
            metric_namespace: 'Pleme/AtticCache',
            tags: tags.merge(Service: 'attic'),
          )

          {
            node_pool_result: node_pool_result,
            nlb: nlb,
            target_group: tg,
            listener: listener,
            cache_bucket: cache_bucket,
            fqdn: fqdn,
            quiescent_scale_policy: quiescent[:scale_policy],
            quiescent_alarm: quiescent[:alarm],
          }
        end
      end
    end
  end
end
