require 'temporal/activity/poller'
require 'temporal/middleware/entry'
require 'temporal/configuration'

describe Temporal::Activity::Poller do
  let(:connection) { instance_double('Temporal::Connection::GRPC', cancel_polling_request: nil) }
  let(:namespace) { 'test-namespace' }
  let(:task_queue) { 'test-task-queue' }
  let(:lookup) { instance_double('Temporal::ExecutableLookup') }
  let(:thread_pool) do
    instance_double(Temporal::ThreadPool, wait_for_available_threads: nil, shutdown: nil)
  end
  let(:config) { Temporal::Configuration.new }
  let(:middleware_chain) { instance_double(Temporal::Middleware::Chain) }
  let(:middleware) { [] }

  subject { described_class.new(namespace, task_queue, lookup, config, middleware) }

  before do
    allow(Temporal::Connection).to receive(:generate).and_return(connection)
    allow(Temporal::ThreadPool).to receive(:new).and_return(thread_pool)
    allow(Temporal::Middleware::Chain).to receive(:new).and_return(middleware_chain)
    allow(Temporal.metrics).to receive(:timing)
  end

  describe '#start' do
    it 'measures time between polls' do
      allow(subject).to receive(:shutting_down?).and_return(false, false, true)
      allow(connection).to receive(:poll_activity_task_queue).and_return(nil)

      subject.start

      # stop poller before inspecting
      subject.stop_polling; subject.wait

      expect(connection)
        .to have_received(:poll_activity_task_queue)
        .with(namespace: namespace, task_queue: task_queue)
        .twice
    end

    it 'reports time since last poll' do
      allow(subject).to receive(:shutting_down?).and_return(false, false, true)
      allow(connection).to receive(:poll_activity_task_queue).and_return(nil)

      subject.start

      # stop poller before inspecting
      subject.stop_polling; subject.wait

      expect(Temporal.metrics)
        .to have_received(:timing)
        .with(
          'activity_poller.time_since_last_poll',
          an_instance_of(Fixnum),
          namespace: namespace,
          task_queue: task_queue
        )
        .twice
    end

    context 'when an activity task is received' do
      let(:task_processor) { instance_double(Temporal::Activity::TaskProcessor, process: nil) }
      let(:task) { Fabricate(:api_activity_task) }

      before do
        allow(subject).to receive(:shutting_down?).and_return(false, true)
        allow(connection).to receive(:poll_activity_task_queue).and_return(task)
        allow(Temporal::Activity::TaskProcessor).to receive(:new).and_return(task_processor)
        allow(thread_pool).to receive(:schedule).and_yield
      end

      it 'schedules task processing using a ThreadPool' do
        subject.start

        # stop poller before inspecting
        subject.stop_polling; subject.wait

        expect(thread_pool).to have_received(:schedule)
      end

      it 'uses TaskProcessor to process tasks' do
        subject.start

        # stop poller before inspecting
        subject.stop_polling; subject.wait

        expect(Temporal::Activity::TaskProcessor)
          .to have_received(:new)
          .with(task, namespace, lookup, middleware_chain, config)
        expect(task_processor).to have_received(:process)
      end

      context 'with middleware configured' do
        class TestPollerMiddleware
          def initialize(_); end
          def call(_); end
        end

        let(:middleware) { [entry_1, entry_2] }
        let(:entry_1) { Temporal::Middleware::Entry.new(TestPollerMiddleware, '1') }
        let(:entry_2) { Temporal::Middleware::Entry.new(TestPollerMiddleware, '2') }

        it 'initializes middleware chain and passes it down to TaskProcessor' do
          subject.start

          # stop poller before inspecting
          subject.stop_polling; subject.wait

          expect(Temporal::Middleware::Chain).to have_received(:new).with(middleware)
          expect(Temporal::Activity::TaskProcessor)
            .to have_received(:new)
            .with(task, namespace, lookup, middleware_chain, config)
        end
      end
    end

    context 'when connection is unable to poll' do
      before do
        allow(subject).to receive(:shutting_down?).and_return(false, true)
        allow(connection).to receive(:poll_activity_task_queue).and_raise(StandardError)
      end

      it 'logs' do
        allow(Temporal.logger).to receive(:error)

        subject.start

        # stop poller before inspecting
        subject.stop_polling; subject.wait

        expect(Temporal.logger)
          .to have_received(:error)
          .with('Unable to poll activity task queue', { namespace: 'test-namespace', task_queue: 'test-task-queue', error: '#<StandardError: StandardError>'})
      end
    end
  end

  describe '#cancel_pending_requests' do
    before { subject.start }
    after { subject.wait }

    it 'tells connection to cancel polling requests' do
      subject.stop_polling
      subject.cancel_pending_requests

      expect(connection).to have_received(:cancel_polling_request)
    end
  end

  describe '#wait' do
    before do
      subject.start
      subject.stop_polling
    end

    it 'shuts down the thread poll' do
      subject.wait

      expect(thread_pool).to have_received(:shutdown)
    end
  end
end
