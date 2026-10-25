# frozen_string_literal: true

module OSPFv2
  # Minimal replacement for the stdlib Observable, which moved out of
  # the default gems in Ruby 3.4. Same API subset: add_observer,
  # delete_observer, changed, notify_observers. Observers get #update.
  module Observable
    def add_observer(observer, func = :update)
      raise NoMethodError, "observer does not respond to `#{func}'" unless observer.respond_to?(func)
      observer_peers[observer] = func
    end

    def delete_observer(observer)
      observer_peers.delete(observer)
    end

    def count_observers
      observer_peers.size
    end

    def changed(state = true)
      @observer_state = state
    end

    def changed?
      !!@observer_state
    end

    def notify_observers(*args)
      return unless @observer_state
      observer_peers.each { |obs, func| obs.__send__(func, *args) }
      @observer_state = false
    end

    private

    def observer_peers
      @observer_peers ||= {}
    end
  end
end
