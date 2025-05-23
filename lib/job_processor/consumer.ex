defmodule JobProcessor.Consumer do
  use GenStage
  require Logger

  def start_link(opts \\ []) do
    GenStage.start_link(__MODULE__, opts)
  end

  def init(opts) do
    subscribe_to = Keyword.get(opts, :subscribe_to, [JobProcessor.Producer])
    Logger.info("Consumer starting, subscribing to: #{inspect(subscribe_to)}")
    
    {:consumer, :state_doesnt_matter, subscribe_to: subscribe_to}
  end

  def handle_events(events, _from, state) do
    # Process each event
    for event <- events do
      Logger.info("Consumer #{inspect(self())} processing event: #{event}")
      # Simulate some work
      Process.sleep(10)
    end
    
    # We must return :noreply
    {:noreply, [], state}
  end
end
