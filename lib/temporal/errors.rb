module Temporal
  # Superclass for all Temporal errors
  class Error < StandardError; end

  # Superclass for errors specific to Temporal worker itself
  class InternalError < Error; end

  # Indicates a non-deterministic workflow execution, might be due to
  # a non-deterministic workflow implementation or the gem's bug
  class NonDeterministicWorkflowError < InternalError; end

  # Superclass for misconfiguration/misuse on the client (user) side
  class ClientError < Error; end

  # Represents any timeout
  class TimeoutError < ClientError; end

  # A superclass for activity exceptions raised explicitly
  # with the intent to propagate to a workflow
  class ActivityException < ClientError; end

  class ActivityNotRegistered < ClientError; end
  class WorkflowNotRegistered < ClientError; end

  class ApiError < Error; end

  class NotFoundFailure < ApiError; end

  # Superclass for system errors raised when retrieving a workflow result on the
  # client, but the workflow failed remotely.
  class WorkflowError < Error; end

  class WorkflowTimedOut < WorkflowError; end
  class WorkflowTerminated < WorkflowError; end
  class WorkflowCanceled < WorkflowError; end

  # Errors where the workflow run didn't complete but not an error for the whole workflow.
  class WorkflowRunError < Error; end
  class WorkflowRunContinuedAsNew < WorkflowRunError
    attr_reader :new_run_id
    def initialize(new_run_id:)
      super
      @new_run_id = new_run_id
    end
  end

  class WorkflowExecutionAlreadyStartedFailure < ApiError
    attr_reader :run_id

    def initialize(message, run_id)
      super(message)
      @run_id = run_id
    end
  end
  class NamespaceNotActiveFailure < ApiError; end
  class ClientVersionNotSupportedFailure < ApiError; end
  class FeatureVersionNotSupportedFailure < ApiError; end
  class NamespaceAlreadyExistsFailure < ApiError; end
  class CancellationAlreadyRequestedFailure < ApiError; end
  class QueryFailedFailure < ApiError; end

end
