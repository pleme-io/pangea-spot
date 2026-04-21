# frozen_string_literal: true

module Pangea
  module Architectures
    module Spot
      # Shared helpers the breathable-daemon architectures
      # (AtticJitService, ZotJitService) use to emit the
      # scale-to-zero backstop alarm. Mirrors the pattern in
      # NixBuilderFleet's `:quiescent_trigger` path — CloudWatch alarm on
      # an "idle" metric, fires an ExactCapacity=0 simple-scaling policy,
      # no Lambda / SNS handler needed.
      module BreathabilityHelpers
        # Emit a scale-to-zero autoscaling_policy + cloudwatch_metric_alarm
        # bound to the supplied ASG name. Returns {scale_policy, alarm}.
        def self.emit_quiescent_scale_to_zero(synth, name:, asg_name:, idle_threshold_secs:,
                                              metric_namespace: 'Pleme/JitService',
                                              metric_name: 'ActiveRequests',
                                              tags: {})
          scale_policy = synth.aws_autoscaling_policy(:"#{name}-scale-to-zero", {
            name: "#{name}-scale-to-zero",
            autoscaling_group_name: asg_name,
            adjustment_type: 'ExactCapacity',
            policy_type: 'SimpleScaling',
            scaling_adjustment: 0,
          })

          alarm = synth.aws_cloudwatch_metric_alarm(:"#{name}-quiescent", {
            alarm_name: "#{name}-quiescent",
            alarm_description:
              "Breathable JIT service #{name} idle (>= #{idle_threshold_secs}s <= 0) — " \
              'backstop alarm that triggers scale-to-zero via an autoscaling ' \
              'ExactCapacity=0 policy. Fires when the service-level liveness ' \
              "metric stays at 0 long enough to justify sleeping the fleet.",
            comparison_operator: 'LessThanOrEqualToThreshold',
            evaluation_periods: 1,
            metric_name: metric_name,
            namespace: metric_namespace,
            period: idle_threshold_secs,
            statistic: 'Sum',
            threshold: 0,
            treat_missing_data: 'notBreaching',
            alarm_actions: [scale_policy.ref(:arn)],
            tags: tags.merge(
              Name: "#{name}-quiescent",
              QuiescentTarget: 'scale-to-zero',
            ),
          })

          { scale_policy: scale_policy, alarm: alarm }
        end

        # Emit a standard S3 bucket for externalized service state with
        # sane defaults: versioning on, default SSE (AES256), public access
        # blocked. Returns the ResourceReference.
        def self.emit_state_bucket(synth, resource_name:, bucket_name:, tags: {})
          bucket = synth.aws_s3_bucket(:"#{resource_name}-bucket", {
            bucket: bucket_name,
            tags: tags.merge(Name: bucket_name),
          })

          synth.aws_s3_bucket_versioning(:"#{resource_name}-bucket-versioning", {
            bucket: bucket.id,
            versioning_configuration: { status: 'Enabled' },
          })

          synth.aws_s3_bucket_server_side_encryption_configuration(
            :"#{resource_name}-bucket-sse",
            {
              bucket: bucket.id,
              rule: [{
                apply_server_side_encryption_by_default: {
                  sse_algorithm: 'AES256',
                },
              }],
            },
          )

          synth.aws_s3_bucket_public_access_block(:"#{resource_name}-bucket-pab", {
            bucket: bucket.id,
            block_public_acls: true,
            block_public_policy: true,
            ignore_public_acls: true,
            restrict_public_buckets: true,
          })

          bucket
        end
      end
    end
  end
end
