require "spec_helper"

RSpec.describe Portage::Ucp::Support::SessionLock do
  let(:locker_class) do
    Class.new do
      include Portage::Ucp::Support::SessionLock

      def guarded(session_id, &block)
        synchronize(session_id, &block)
      end
    end
  end

  it "is private — synchronize is adapter-internal, not part of the Adapter contract" do
    expect(locker_class.new).not_to respond_to(:synchronize)
  end

  it "runs the block and returns its value" do
    locker = locker_class.new
    expect(locker.guarded("cart-1") { "result" }).to eq("result")
  end

  it "serializes concurrent calls on the same session id" do
    locker = locker_class.new
    concurrency_mutex = Mutex.new
    concurrent_count = 0
    max_concurrent = 0
    release = Queue.new

    threads = Array.new(2) do
      Thread.new do
        locker.guarded("cart-1") do
          concurrency_mutex.synchronize do
            concurrent_count += 1
            max_concurrent = [max_concurrent, concurrent_count].max
          end
          release.pop
          concurrency_mutex.synchronize { concurrent_count -= 1 }
        end
      end
    end

    # let both threads queue up on the lock before releasing either
    sleep 0.05
    release << true
    release << true
    threads.each(&:join)

    expect(max_concurrent).to eq(1)
  end

  it "does not serialize calls on different session ids" do
    locker = locker_class.new
    ready = Queue.new
    release = Queue.new

    thread = Thread.new do
      locker.guarded("cart-1") do
        ready << true
        release.pop
      end
    end

    ready.pop
    expect(locker.guarded("cart-2") { "concurrent" }).to eq("concurrent")

    release << true
    thread.join
  end
end
