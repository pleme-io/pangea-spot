# frozen_string_literal: true

require 'pangea/architectures/spot/types'
require 'pangea/architectures/spot/k8s_jit_node_pool'
require 'pangea/architectures/spot/breathability_helpers'

module Pangea
  module Architectures
    module Spot
      # MlJitTraining — spot-backed ML training pool with checkpoint-based
      # interruption resilience.
      #
      # GPU spot interruption rates run 10-20% depending on region/instance
      # family (2026 data). A 2-hour training run that doesn't checkpoint
      # is effectively certain to be reclaimed once or twice. The only
      # way to use spot for training WITHOUT catastrophic utility loss is
      # to checkpoint aggressively and resume on a fresh instance after
      # reclaim.
      #
      # JIT five-dimension composition:
      #   - auction substrate   → K8sJitNodePool (profile default
      #                           :karpenter_gpu; GPU pools stay small,
      #                           max_size default 4)
      #   - breathability       → scale-to-zero when no training jobs
      #                           queued; first-job wake takes ~2-4min
      #                           (GPU instance launch + CUDA init)
      #   - state externalization → S3 checkpoint bucket (aggressive
      #                           default cadence: every 30 minutes).
      #                           Training job watches CheckpointCadence
      #                           instance tag and writes to
      #                           CheckpointStorageUri.
      #   - interruption policy → `:checkpoint_job` (via K8sJitNodePool's
      #                           `interruption_policy_override`) —
      #                           interruption event triggers checkpoint
      #                           Lambda, NOT a cordon+drain. The Lambda
      #                           signals the training job to flush state
      #                           to S3 and exit cleanly; next instance
      #                           resumes from latest checkpoint on boot.
      #   - substrate provider  → AWS ASG (via MixedInstancesAsg inside
      #                           K8sJitNodePool)
      #
      # Checkpoint policy (CheckpointPolicyConfig) is propagated to the
      # training job as launch-template instance tags:
      #   - CheckpointCadence (minutes)
      #   - CheckpointStorageUri (s3://bucket/prefix)
      #   - ResumeFromLatest (bool)
      #
      # Returns:
      #   { node_pool_result:, checkpoint_bucket:, checkpoint_policy: }
      module MlJitTraining
        def self.build(synth, config = {})
          config = Types::MlJitTrainingConfig.new(config).to_h

          synth.extend(Pangea::Resources::AWS) unless synth.respond_to?(:aws_s3_bucket)

          name = config[:name]
          tags = config[:tags] || {}

          # ── Checkpoint state bucket ───────────────────────────────────
          bucket_name = config[:checkpoint_bucket_name] || "#{name}-ml-checkpoints"
          checkpoint_bucket = BreathabilityHelpers.emit_state_bucket(
            synth,
            resource_name: "#{name}-ml",
            bucket_name: bucket_name,
            tags: tags.merge(Workload: 'ml-training'),
          )

          checkpoint_storage_uri = "s3://#{bucket_name}/#{name}/checkpoints"

          # ── Node pool with :checkpoint_job interruption policy ────────
          # Checkpoint metadata lands on the launch-template instance
          # tags so the training job code can read them at boot and
          # configure its own cadence + resume logic without any
          # in-cluster config surface.
          checkpoint_tags = {
            Workload: 'ml-training',
            CheckpointCadence: config[:checkpoint_cadence_minutes].to_s,
            CheckpointStorageUri: checkpoint_storage_uri,
            CheckpointBucket: bucket_name,
            ResumeFromLatest: config[:resume_from_latest].to_s,
          }

          node_pool_result = K8sJitNodePool.build(synth, {
            name: "#{name}-ml",
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
            node_labels: config[:node_labels],
            node_taints: config[:node_taints],
            interruption_policy: :checkpoint_job,
            lambda_function_arn: config[:lambda_checkpoint_arn],
            tags: tags.merge(checkpoint_tags),
          })

          {
            node_pool_result: node_pool_result,
            checkpoint_bucket: checkpoint_bucket,
            checkpoint_policy: {
              cadence_minutes: config[:checkpoint_cadence_minutes],
              storage_uri: checkpoint_storage_uri,
              bucket_name: bucket_name,
              resume_from_latest: config[:resume_from_latest],
            },
          }
        end
      end
    end
  end
end
