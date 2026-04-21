# frozen_string_literal: true

require 'json'
require 'pangea/architectures/spot/types'

module Pangea
  module Architectures
    module Spot
      # Spot interruption handler — wires AWS's 2-minute-warning
      # EventBridge event into a pluggable handler (SNS, Lambda,
      # lifecycle hook). Four policies map to four compositions:
      #
      #   naive_terminate      nothing; accept the hit. (still emits
      #                        the EB rule so you can observe.)
      #   graceful_terminate   EB rule → SNS topic. Downstream (ASG
      #                        lifecycle hook or external consumer)
      #                        drains gracefully.
      #   drain_k8s_node       EB rule → Lambda cordons + drains the
      #                        matching k8s node via pre-signed kubeconfig.
      #                        (Lambda code supplied separately.)
      #   checkpoint_job       EB rule → Lambda signals the job
      #                        runner (e.g. SQS message) to checkpoint
      #                        state to S3 before termination.
      #
      # This architecture emits the infra skeleton for all four. Lambda
      # source code is out of scope (shipped as a separate zip built
      # elsewhere — e.g. cordel-core spot-handler). Consumers subscribe
      # to the SNS topic (graceful_terminate) or wire a Lambda to it
      # (drain_k8s_node / checkpoint_job) through the optional
      # :lambda_function_arn field.
      #
      # Emits:
      #   aws_cloudwatch_event_rule  — captures the spot interruption
      #   aws_cloudwatch_event_target — routes to sns or lambda
      #   aws_sns_topic              — when policy in {graceful_terminate}
      #   aws_lambda_permission      — when :lambda_function_arn is set
      #   aws_autoscaling_lifecycle_hook — when :asg_name is set; holds
      #       the instance in Terminating:Wait until the handler completes
      #
      # Reference AWS docs:
      #   https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/
      #     spot-interruption-notices.html
      module InterruptionHandler
        POLICIES = %i[
          naive_terminate
          graceful_terminate
          drain_k8s_node
          checkpoint_job
        ].freeze

        # Pattern matches AWS's EventBridge event for spot interruption.
        EVENT_PATTERN = {
          source: ['aws.ec2'],
          'detail-type': ['EC2 Spot Instance Interruption Warning'],
        }.freeze

        # Optional: match capacity-rebalancing events too. These fire
        # EARLIER than the 2-min warning, giving handlers a head start.
        EVENT_PATTERN_WITH_REBALANCE = {
          source: ['aws.ec2'],
          'detail-type': [
            'EC2 Spot Instance Interruption Warning',
            'EC2 Instance Rebalance Recommendation',
          ],
        }.freeze

        def self.build(synth, config = {})
          config = Types::SpotInterruptionHandlerConfig.new(config).to_h

          policy = config[:policy].to_sym
          raise ArgumentError, "policy must be one of #{POLICIES}, got #{policy}" unless POLICIES.include?(policy)

          synth.extend(Pangea::Resources::AWS) unless synth.respond_to?(:aws_cloudwatch_event_rule)

          name = config[:name]
          tags = (config[:tags] || {}).merge(Name: name, SpotPolicy: policy.to_s)

          pattern = config[:include_rebalance_events] ? EVENT_PATTERN_WITH_REBALANCE : EVENT_PATTERN
          rule = synth.aws_cloudwatch_event_rule(:"#{name}-spot-rule", {
            name: "#{name}-spot-interruption",
            description: "Spot interruption + rebalance warnings for #{name} (#{policy})",
            event_pattern: JSON.generate(pattern),
            tags: tags,
          })

          # ── SNS topic (graceful_terminate → ops consume) ──────────────
          topic = nil
          if policy == :graceful_terminate
            topic = synth.aws_sns_topic(:"#{name}-spot-topic", {
              name: "#{name}-spot-interruption",
              display_name: "#{name} spot interruption",
              tags: tags,
            })
            synth.aws_cloudwatch_event_target(:"#{name}-spot-target-sns", {
              rule:      rule.ref(:name),
              target_id: "#{name}-spot-sns",
              arn:       topic.ref(:arn),
            })
          end

          # ── Lambda target (drain_k8s_node / checkpoint_job) ───────────
          lambda_permission = nil
          if config[:lambda_function_arn] && %i[drain_k8s_node checkpoint_job].include?(policy)
            synth.aws_cloudwatch_event_target(:"#{name}-spot-target-lambda", {
              rule:      rule.ref(:name),
              target_id: "#{name}-spot-lambda",
              arn:       config[:lambda_function_arn],
            })
            lambda_permission = synth.aws_lambda_permission(:"#{name}-spot-lambda-perm", {
              statement_id:  "AllowSpotInterruptionFrom-#{name}",
              action:        'lambda:InvokeFunction',
              function_name: config[:lambda_function_arn],
              principal:     'events.amazonaws.com',
              source_arn:    rule.ref(:arn),
            })
          end

          # ── ASG lifecycle hook (hold in Terminating:Wait) ─────────────
          # Covers the post-2-minute gap: once the spot notice fires, the
          # instance still has ~2 min before EC2 force-terminates. The
          # lifecycle hook gives the handler that window plus additional
          # configurable heartbeats.
          lifecycle_hook = nil
          if config[:asg_name] && policy != :naive_terminate
            lifecycle_hook = synth.aws_autoscaling_lifecycle_hook(:"#{name}-spot-lifecycle", {
              name:                    "#{name}-spot-terminating",
              autoscaling_group_name:  config[:asg_name],
              lifecycle_transition:    'autoscaling:EC2_INSTANCE_TERMINATING',
              heartbeat_timeout:       config[:lifecycle_heartbeat_timeout] || 120,
              default_result:          'CONTINUE',
              notification_target_arn: topic ? topic.ref(:arn) : nil,
              role_arn:                config[:lifecycle_role_arn],
            }.compact)
          end

          {
            rule:              rule,
            topic:             topic,
            lambda_permission: lambda_permission,
            lifecycle_hook:    lifecycle_hook,
            policy:            policy,
          }
        end
      end
    end
  end
end
