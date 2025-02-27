require 'temporal/testing'
require 'temporal/workflow'
require 'temporal/api/errordetails/v1/message_pb'

describe Temporal::Testing::TemporalOverride do
  class TestTemporalOverrideWorkflow < Temporal::Workflow
    namespace 'default-namespace'
    task_queue 'default-task-queue'

    def execute; end
  end

  context 'when testing mode is disabled' do
    describe 'Temporal.start_workflow' do
      let(:connection) { instance_double('Temporal::Connection::GRPC') }
      let(:response) { Temporal::Api::WorkflowService::V1::StartWorkflowExecutionResponse.new(run_id: 'xxx') }

      before { allow(Temporal::Connection).to receive(:generate).and_return(connection) }
      after { Temporal.remove_instance_variable(:@connection) rescue NameError }

      it 'invokes original implementation' do
        allow(connection).to receive(:start_workflow_execution).and_return(response)

        Temporal.start_workflow(TestTemporalOverrideWorkflow)

        expect(connection)
          .to have_received(:start_workflow_execution)
          .with(hash_including(workflow_name: 'TestTemporalOverrideWorkflow'))
      end
    end
  end

  context 'when testing mode is local' do
    around do |example|
      Temporal::Testing.local! { example.run }
    end

    describe 'Temporal.schedule_workflow' do
      it 'allows the test to simulate deferred executions' do
        workflow = TestTemporalOverrideWorkflow.new(nil)
        workflow2 = TestTemporalOverrideWorkflow.new(nil)
        allow(TestTemporalOverrideWorkflow).to receive(:new).and_return(workflow, workflow2)

        allow(workflow).to receive(:execute)
        allow(workflow2).to receive(:execute)
        Temporal.schedule_workflow(TestTemporalOverrideWorkflow, '* * * * *')
        Temporal.schedule_workflow(TestTemporalOverrideWorkflow, '1 */5 * * *')
        expect(workflow).not_to have_received(:execute)
        expect(workflow2).not_to have_received(:execute)

        Temporal::Testing::ScheduledWorkflows.execute_all
        expect(workflow).to have_received(:execute)
        expect(workflow2).to have_received(:execute)
      end

      it 'allows the test to simulate a particular deferred execution' do
        workflow = TestTemporalOverrideWorkflow.new(nil)
        allow(TestTemporalOverrideWorkflow).to receive(:new).and_return(workflow)
        allow(workflow).to receive(:execute)
        Temporal.schedule_workflow(TestTemporalOverrideWorkflow, '*/3 * * * *', options: { workflow_id: 'my_id' })
        expect(workflow).not_to have_received(:execute)
        expect(Temporal::Testing::ScheduledWorkflows.cron_schedules['my_id']).to eq('*/3 * * * *')

        Temporal::Testing::ScheduledWorkflows.execute(workflow_id: 'my_id')
        expect(workflow).to have_received(:execute)
      end

      it 'complains when an invalid deferred execution is specified' do
        expect do
          Temporal::Testing::ScheduledWorkflows.execute(workflow_id: 'invalid_id')
        end.to raise_error(
          Temporal::Testing::WorkflowIDNotScheduled,
          /There is no workflow with id invalid_id that was scheduled with Temporal.schedule_workflow./
        )
      end

      it 'can clear scheduled executions' do
        workflow = TestTemporalOverrideWorkflow.new(nil)
        allow(TestTemporalOverrideWorkflow).to receive(:new).and_return(workflow)
        allow(workflow).to receive(:execute)
        Temporal.schedule_workflow(TestTemporalOverrideWorkflow, '* * * * *')
        expect(workflow).not_to have_received(:execute)
        expect(Temporal::Testing::ScheduledWorkflows.cron_schedules).not_to be_empty

        Temporal::Testing::ScheduledWorkflows.clear_all
        Temporal::Testing::ScheduledWorkflows.execute_all
        expect(workflow).not_to have_received(:execute)
        expect(Temporal::Testing::ScheduledWorkflows.cron_schedules).to be_empty
      end
    end

    describe 'Workflow.execute_locally' do
      it 'executes the workflow' do
        workflow = TestTemporalOverrideWorkflow.new(nil)
        allow(TestTemporalOverrideWorkflow).to receive(:new).and_return(workflow)
        allow(workflow).to receive(:execute)

        TestTemporalOverrideWorkflow.execute_locally

        expect(workflow).to have_received(:execute)
      end

      it 'restores original context after finishing successfully' do
        TestTemporalOverrideWorkflow.execute_locally
        expect(Temporal::ThreadLocalContext.get).to eq(nil)
      end

      class FailingWorkflow
        def execute
          raise 'uh oh'
        end
      end

      it 'restores original context after failing' do
        expect { FailingWorkflow.execute_locally }.to raise_error(StandardError)
        expect(Temporal::ThreadLocalContext.get).to eq(nil)
      end
    end

    describe 'Temporal.start_workflow' do
      let(:workflow) { TestTemporalOverrideWorkflow.new(nil) }

      before { allow(TestTemporalOverrideWorkflow).to receive(:new).and_return(workflow) }

      it 'calls the workflow directly' do
        allow(workflow).to receive(:execute)

        Temporal.start_workflow(TestTemporalOverrideWorkflow)

        expect(workflow).to have_received(:execute)
        expect(TestTemporalOverrideWorkflow)
          .to have_received(:new)
          .with(an_instance_of(Temporal::Testing::LocalWorkflowContext))
      end

      describe 'execution control' do
        subject do
          Temporal.start_workflow(
            TestTemporalOverrideWorkflow,
            options: { workflow_id: workflow_id, workflow_id_reuse_policy: policy }
          )
        end

        let(:execution) { instance_double(Temporal::Testing::WorkflowExecution, status: status) }
        let(:workflow_id) { SecureRandom.uuid }
        let(:run_id) { SecureRandom.uuid }
        let(:error_class) { Temporal::WorkflowExecutionAlreadyStartedFailure }

        # Simulate existing execution
        before do
          if execution
            Temporal.send(:executions)[[workflow_id, run_id]] = execution
          end
        end

        context 'reuse policy is :allow_failed' do
          let(:policy) { :allow_failed }

          context 'when workflow was not yet started' do
            let(:execution) { nil }

            it { is_expected.to be_a(String) }
          end

          context 'when workflow is started' do
            let(:status) { Temporal::Workflow::ExecutionInfo::RUNNING_STATUS }

            it 'raises error' do
              expect { subject }.to raise_error(error_class) { |e| expect(e.run_id).to eql(run_id) }
            end
          end

          context 'when workflow has completed' do
            let(:status) { Temporal::Workflow::ExecutionInfo::COMPLETED_STATUS }

            it 'raises error' do
              expect { subject }.to raise_error(error_class) { |e| expect(e.run_id).to eql(run_id) }
            end
          end

          context 'when workflow has failed' do
            let(:status) { Temporal::Workflow::ExecutionInfo::FAILED_STATUS }

            it { is_expected.to be_a(String) }
          end
        end

        context 'reuse policy is :allow' do
          let(:policy) { :allow }

          context 'when workflow was not yet started' do
            let(:execution) { nil }

            it { is_expected.to be_a(String) }
          end

          context 'when workflow is started' do
            let(:status) { Temporal::Workflow::ExecutionInfo::RUNNING_STATUS }

            it 'raises error' do
              expect { subject }.to raise_error(error_class) { |e| expect(e.run_id).to eql(run_id) }
            end
          end

          context 'when workflow has completed' do
            let(:status) { Temporal::Workflow::ExecutionInfo::COMPLETED_STATUS }

            it { is_expected.to be_a(String) }
          end

          context 'when workflow has failed' do
            let(:status) { Temporal::Workflow::ExecutionInfo::FAILED_STATUS }

            it { is_expected.to be_a(String) }
          end
        end

        context 'reuse policy is :reject' do
          let(:policy) { :reject }

          context 'when workflow was not yet started' do
            let(:execution) { nil }

            it { is_expected.to be_a(String) }
          end

          context 'when workflow is started' do
            let(:status) { Temporal::Workflow::ExecutionInfo::RUNNING_STATUS }

            it 'raises error' do
              expect { subject }.to raise_error(error_class) { |e| expect(e.run_id).to eql(run_id) }
            end
          end

          context 'when workflow has completed' do
            let(:status) { Temporal::Workflow::ExecutionInfo::COMPLETED_STATUS }

            it 'raises error' do
              expect { subject }.to raise_error(error_class) { |e| expect(e.run_id).to eql(run_id) }
            end
          end

          context 'when workflow has failed' do
            let(:status) { Temporal::Workflow::ExecutionInfo::FAILED_STATUS }

            it 'raises error' do
              expect { subject }.to raise_error(error_class) { |e| expect(e.run_id).to eql(run_id) }
            end
          end
        end
      end
    end
  end
end
