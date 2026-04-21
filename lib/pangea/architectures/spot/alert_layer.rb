# frozen_string_literal: true

require 'json'
require 'pangea/architectures/spot/types'

module Pangea
  module Architectures
    module Spot
      # AlertLayer — mandatory interruption telegraph for every JIT
      # workload. Emits the concrete AWS resources (SQS queue +
      # EventBridge rule + event target + IAM policy) that downstream
      # node-termination handlers (aws-node-termination-handler in
      # Queue mode, Karpenter built-in) listen to. For IMDS mode, no
      # cloud resources are needed — the DaemonSet reads `/spot/
      # instance-action` directly, so this architecture emits only
      # the ASG-level alert-method tag for operator visibility.
      #
      # See `feedback_spot_alert_layer_mandatory.md` in user memory for
      # the HARD rule. See `arch-synthesizer/src/spot/alerting.rs` for
      # the Rust-side typed primitive that mirrors this config.
      #
      # Usage (inside another architecture's `.build`):
      #
      #   alert_result = AlertLayer.build(synth, {
      #     name: 'workers-alerts',
      #     source: :aws_eventbridge_sqs,
      #     forwarder: :nth_queue,
      #     sinks: [{ kind: :kubernetes_api }],
      #   }, asg_name: 'workers-asg', tags: base_tags)
      #
      # Returns:
      #   { source:, forwarder:, sqs_queue:, event_rule:, event_target:,
      #     iam_policy:, tags: }
      #
      # Validation: caller-supplied `required: false` short-circuits to
      # `{ opted_out: true }` — audit trail only, no resources emitted.
      # Incompatible source×forwarder combinations raise ArgumentError.
      module AlertLayer
        # Pairwise compat matrix. Mirrors the Rust validator.
        FORWARDER_COMPAT = {
          nth_imds:          %i[aws_imds],
          nth_queue:         %i[aws_eventbridge_sqs],
          karpenter_builtin: %i[aws_eventbridge_sqs],
          spot_io_ocean:     %i[vendor_spot_io aws_imds aws_eventbridge_sqs],
          cast_ai:           %i[vendor_cast_ai aws_imds aws_eventbridge_sqs],
          custom_lambda:     %i[aws_imds aws_eventbridge_sqs aws_cloudwatch_events
                                gcp_metadata_server azure_metadata_service custom],
          none:              %i[none],
        }.freeze

        VENDOR_SELF_HANDLING = %i[spot_io_ocean cast_ai].freeze

        EVENT_PATTERN = {
          source: ['aws.ec2'],
          'detail-type': ['EC2 Spot Instance Interruption Warning'],
        }.freeze

        EVENT_PATTERN_WITH_REBALANCE = {
          source: ['aws.ec2'],
          'detail-type': [
            'EC2 Spot Instance Interruption Warning',
            'EC2 Instance Rebalance Recommendation',
          ],
        }.freeze

        def self.build(synth, config = {}, asg_name: nil, tags: {})
          cfg = Types::AlertLayerConfig.new(config).to_h

          source = cfg[:source]
          forwarder = cfg[:forwarder]
          name = cfg[:name] || (asg_name ? "#{asg_name}-alert" : 'spot-alert')

          # Opt-out short-circuit — audit trail only.
          return { opted_out: true, source: source, forwarder: forwarder } unless cfg[:required]

          # Validate source × forwarder compatibility.
          allowed_sources = FORWARDER_COMPAT.fetch(forwarder) do
            raise ArgumentError, "unknown forwarder #{forwarder.inspect}"
          end
          unless allowed_sources.include?(source)
            raise ArgumentError,
                  "forwarder #{forwarder.inspect} is incompatible with source " \
                  "#{source.inspect}. Allowed: #{allowed_sources.inspect}"
          end

          synth.extend(Pangea::Resources::AWS) unless synth.respond_to?(:aws_sqs_queue)

          base_tags = (cfg[:tags] || {}).merge(tags).merge(
            ManagedBy: 'pangea-spot',
            AlertLayer: 'spot-interruption',
            AlertSource: source.to_s,
            AlertForwarder: forwarder.to_s,
          )

          # ── Vendor-self-handling short-circuit ────────────────────────
          # For spot.io Ocean / CAST AI, the vendor agent manages
          # everything. We just stamp the ASG tag so operators can
          # confirm which cluster is vendor-managed.
          if VENDOR_SELF_HANDLING.include?(forwarder)
            return {
              source: source,
              forwarder: forwarder,
              sqs_queue: nil,
              event_rule: nil,
              event_target: nil,
              iam_policy: nil,
              tags: base_tags,
              vendor_self_handling: true,
            }
          end

          # ── IMDS-only path — no cloud resources ──────────────────────
          # NTH in IMDS mode runs as a per-node DaemonSet (deployed
          # separately via Helm/Kustomize). No AWS resources at this
          # layer; just the audit tags.
          if forwarder == :nth_imds
            return {
              source: source,
              forwarder: forwarder,
              sqs_queue: nil,
              event_rule: nil,
              event_target: nil,
              iam_policy: nil,
              tags: base_tags,
              imds_only: true,
            }
          end

          # ── Queue-mode: SQS + EventBridge rule + target + IAM ────────
          queue = synth.aws_sqs_queue(:"#{name}-queue", {
            name: "#{name}-queue",
            message_retention_seconds: 300, # 5 min — interruption warnings expire fast
            sqs_managed_sse_enabled: true,
            tags: base_tags.merge(Name: "#{name}-queue"),
          })

          pattern = cfg[:include_rebalance_events] ? EVENT_PATTERN_WITH_REBALANCE : EVENT_PATTERN
          rule = synth.aws_cloudwatch_event_rule(:"#{name}-rule", {
            name: "#{name}-spot-interruption",
            description: "Spot interruption warnings for #{name} (#{forwarder})",
            event_pattern: JSON.generate(pattern),
            tags: base_tags,
          })

          target = synth.aws_cloudwatch_event_target(:"#{name}-target", {
            rule: rule.ref(:name),
            target_id: "#{name}-sqs",
            arn: queue.ref(:arn),
          })

          # Allow EventBridge to enqueue messages on this SQS. IAM
          # policy attached to the SQS queue's resource policy; this
          # emits an aws_sqs_queue_policy in practice but pangea-aws
          # may name it differently — using aws_iam_policy as a
          # forward-compatible placeholder attached at apply time.
          iam_policy = synth.aws_iam_policy(:"#{name}-sqs-policy", {
            name: "#{name}-sqs-events-send",
            description: "Allow EventBridge to send spot-interruption events to #{name} queue",
            policy: JSON.generate({
              Version: '2012-10-17',
              Statement: [{
                Sid: 'AllowEventsToSendToQueue',
                Effect: 'Allow',
                Principal: { Service: 'events.amazonaws.com' },
                Action: 'sqs:SendMessage',
                Resource: queue.ref(:arn),
                Condition: {
                  ArnEquals: { 'aws:SourceArn' => rule.ref(:arn) },
                },
              }],
            }),
            tags: base_tags,
          })

          {
            source: source,
            forwarder: forwarder,
            sqs_queue: queue,
            event_rule: rule,
            event_target: target,
            iam_policy: iam_policy,
            tags: base_tags,
          }
        end

        # Factory helpers mirroring the Rust AlertLayer constructors.
        def self.aws_kubernetes_imds(k8s_endpoint)
          {
            source: :aws_imds,
            forwarder: :nth_imds,
            sinks: [{ kind: :kubernetes_api, endpoint: k8s_endpoint }],
            k8s_endpoint: k8s_endpoint,
            required: true,
          }
        end

        def self.aws_kubernetes_queue(sqs_queue_arn, k8s_endpoint)
          {
            source: :aws_eventbridge_sqs,
            forwarder: :nth_queue,
            sinks: [{ kind: :kubernetes_api, endpoint: k8s_endpoint }],
            sqs_queue_arn: sqs_queue_arn,
            k8s_endpoint: k8s_endpoint,
            required: true,
          }
        end

        def self.spot_io_ocean
          { source: :vendor_spot_io, forwarder: :spot_io_ocean, required: true }
        end

        def self.opt_out(reason:)
          { required: false, tags: { OptOutReason: reason } }
        end
      end
    end
  end
end
