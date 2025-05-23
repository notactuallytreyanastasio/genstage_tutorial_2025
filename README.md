# Writing A Job Runner (In Elixir)

Applications must do work. This is typical of just about any program that reaches a sufficient size. In order to do that work, sometimes it's desirable to have it happen *elsewhere*. If you have built software, you have probably needed a background job.

In this situation, you are fundamentally using code to run other code. Erlang has a nice format for this, called the Erlang term format. It can store its data in a way it can be passed around and run by other nodes We are going to examine doing this in Elixir with "tools in the shed". We will have a single dependency called `gen_stage` that is built and maintained by the language's creator, Jose Valim.

For beginners, we will first cover a bit about Elixir and what it offers that might make this appealing

## The Landscape of Job Processing

In Ruby, you might reach for Sidekiq. It's battle-tested, using Redis for storage and threads for concurrency. Jobs are JSON objects, workers pull from queues, and if something crashes, you hope your monitoring catches it. It works well until you need to scale beyond a single Redis instance or handle complex job dependencies.

Python developers often turn to Celery. It's more distributed by design, supporting multiple brokers and result backends. But the complexity shows - you're configuring RabbitMQ, dealing with serialization formats, and debugging issues across multiple moving parts. When a worker dies mid-job, recovery depends on how well you've configured acknowledgments and retries.

Go developers might use machinery or asynq, leveraging goroutines for concurrency. The static typing helps catch errors early, but you're still manually managing worker pools and carefully handling panics to prevent the whole process from dying.

Each solution reflects its language's strengths and limitations. They all converge on similar patterns: a persistent queue, worker processes, and lots of defensive programming. What if the language itself provided better primitives for this problem?

# Thinking About Job Runners, Producers, Consumers, and Events

## The Architecture of Work

At its core, a job runner is a meta concept. It is code that runs code. There will always be work to be done in any given system that has users. But ensuring work gets done when it cannot be handled in a blocking, synchronous matter (and you have the time to await results) is nearly impossible. The devil is in these details. How do you handle failure? What is our plan when we have a situation that could overwhelm our worker pool? We seek out answers to these questions as we do this dive.

GenStage answers the questions we have asked so far, in general, with demand driven architecture. Instead of pushing work out, workers pull when *they* are ready. This inversion becomes a very elegant abstraction in practice.

## Understanding Producer-Consumer Patterns

The producer-consumer pattern isn't unique to Elixir. It's a fundamental pattern in distributed systems:

**In Apache Spark**, RDDs (Resilient Distributed Datasets) flow through transformations. Each transformation is essentially a consumer of the previous stage and a producer for the next. Spark handles backpressure through its task scheduler - if executors are busy, new tasks wait.

**In Kafka Streams**, topics act as buffers between producers and consumers. Consumers track their offset, pulling messages at their own pace. The broker handles persistence and replication.

**In Go channels**, goroutines communicate through typed channels. A goroutine blocks when sending to a full channel or receiving from an empty one. This provides natural backpressure but requires careful capacity planning.

GenStage takes a different approach. There are no intermediate buffers or brokers. Producers and consumers negotiate directly:

1. Consumer asks producer for work (specifying how much it can handle)
2. Producer responds with up to that many events
3. Consumer processes events and asks for more

This creates a pull-based system with automatic flow control. No queues filling up, no brokers to manage, no capacity planning. The system self-regulates based on actual processing speed.

## What We're Actually Building

### Why Elixir Works for Job Processing

**Processes are the unit of concurrency.** Not threads, not coroutines - processes. Each process has its own heap, runs concurrently, and can't corrupt another's memory. Starting one is measured in microseconds and takes about 2KB of memory. You don't manage a pool of workers; you spawn a process per job.

**Failure is isolated by default.** When a process crashes, it dies alone. No corrupted global state, no locked mutexes, no zombie threads. The supervisor sees the death, logs it, and starts a fresh process. Your job processor doesn't need defensive try-catch blocks everywhere - it needs a good supervision tree.

**Message passing is the only way to communicate.** No shared memory means no locks, no race conditions, no memory barriers. A process either receives a message or it doesn't. This constraint simplifies concurrent programming dramatically - you can reason about each process in isolation.

**The scheduler handles fairness.** The BEAM VM runs its own scheduler, preemptively switching between processes every 2000 reductions. One process can't starve others by hogging the CPU. This is why Phoenix can handle millions of WebSocket connections - each connection is just another lightweight process.

**Distribution is built-in.** Connect nodes with one function call. Send messages across the network with the same syntax as local messages. The Erlang Term Format serializes any data structure, including function references. Your job queue can span multiple machines without changing the core logic.

**Hot code reloading works.** Deploy new code without stopping the system. The BEAM can run two versions of a module simultaneously, migrating processes gracefully. Your job processor can be upgraded while it's processing jobs.

**Introspection is exceptional.** Connect to a running system and inspect any process. See its message queue, memory usage, current function. The observer GUI shows your entire system's health in real-time. When production misbehaves, you can debug it live.

These aren't features bolted on top - they're fundamental to how the BEAM VM works. When you build a job processor in Elixir, you're not fighting the language to achieve reliability and concurrency. You're using it as designed.

Our job runner will have three core components:

**Producers** - These generate or fetch work. In our case, they'll pull jobs from a database table. A producer doesn't decide who gets work - it simply responds to demand. When a consumer asks for 10 jobs, the producer queries the database for 10 unclaimed jobs and returns them.

**Consumers** - These execute jobs. Each consumer is a separate Elixir process, isolated from others. When a consumer is ready for work, it asks its producer for events. After processing, it asks for more. If a consumer crashes while processing a job, only that job is affected.

**Events** - The unit of work flowing through the system. In GenStage, everything is an event. For our job runner, an event is a job to be executed. Events flow from producers to consumers based on demand, never faster than consumers can handle.

## The Beauty of Modeling Everything as Events

When you model work as events, powerful patterns emerge:

**Composition** - You can chain stages together. A consumer can also be a producer for another stage. Want to add a step that enriches jobs before execution? Insert a producer-consumer between your current stages.

**Fan-out/Fan-in** - One producer can feed multiple consumers (fan-out). Multiple producers can feed one consumer (fan-in). The demand mechanism ensures fair distribution.

**Buffering** - Need a buffer? Add a producer-consumer that accumulates events before passing them on. The buffer only fills as fast as downstream consumers can drain it.

**Filtering** - A producer-consumer can selectively forward events. Only want to process high-priority jobs? Filter them in a middle stage.

```
Event Flow Pipeline: Social Media Processing

[BlueSky] ──┐
[Twitter] ──┼──→ [Producer] ═══→ [ProducerConsumer] ═══→ [Consumer] ──→ [Database]
[TikTok]  ──┘                    (transformation)

Flow: Social media posts → Producer → Transformation → Consumer → Storage
```

## Why This Matters for Job Processing

Traditional job processors push jobs into queues. Workers poll these queues, hoping to grab work. This creates several problems:

1. **Queue overflow** - Producers can overwhelm the queue if consumers are slow
2. **Unfair distribution** - Fast workers might grab all the work
3. **Visibility** - Hard to see where bottlenecks are
4. **Error handling** - What happens to in-flight jobs when a worker dies?

GenStage's demand-driven model solves these elegantly:

1. **No overflow** - Producers only generate what's demanded
2. **Fair distribution** - Each consumer gets what it asks for
3. **Clear bottlenecks** - Slow stages naturally build up demand
4. **Clean errors** - Crashed consumers simply stop demanding; their work remains unclaimed

This isn't theoretical. Telecom systems have used these patterns for decades. When you make a phone call, switches don't push calls through the network - each hop pulls when ready. This prevents network overload even during disasters when everyone tries to call at once.

We're applying the same battle-tested patterns to job processing. The result is a system that's naturally resilient, self-balancing, and surprisingly simple to reason about.

Ready to see how this translates to code? Let's build our first producer.

# Building the Foundation

## Step 1: Creating Your Phoenix Project

Let's start fresh with a new Phoenix project. Open your terminal and run:

```
mix phx.new job_processor --no-dashboard --no-mailer
cd job_processor
```

We're keeping it lean - no dashboard or mailer for now. When prompted to install dependencies, say yes.

Why Phoenix? We're not building a web app, but Phoenix gives us:
- A supervision tree already set up
- Configuration management
- A database connection (Ecto)
- LiveView for our monitoring dashboard (later)

Think of Phoenix as our application framework, not just a web framework.

## Step 2: Adding GenStage

Open `mix.exs` and add GenStage to your dependencies:

```elixir
defp deps do
  [
    {:phoenix, "~> 1.7.12"},
    {:phoenix_ecto, "~> 4.5"},
    {:ecto_sql, "~> 3.11"},
    {:postgrex, ">= 0.0.0"},
    {:phoenix_html, "~> 4.1"},
    {:phoenix_live_reload, "~> 1.2", only: :dev},
    {:phoenix_live_view, "~> 0.20.14"},
    {:telemetry_metrics, "~> 0.6"},
    {:telemetry_poller, "~> 1.0"},
    {:jason, "~> 1.2"},
    {:bandit, "~> 1.2"},

    # Add this line
    {:gen_stage, "~> 1.2"}
  ]
end
```

Now fetch the dependency:

```
mix deps.get
```

That's it. One dependency. GenStage is maintained by the Elixir core team, so it follows the same design principles as the language itself.

## Step 3: Understanding GenStage's Mental Model

Before we write code, let's cement the mental model. GenStage orchestrates three types of processes:

**Producers** emit events. They don't push events anywhere - they hold them until a consumer asks. Think of a producer as a lazy river of data. The water (events) only flows when someone downstream opens a valve (demands).

**Consumers** receive events. They explicitly ask producers for a specific number of events. This is the key insight: consumers control the flow rate, not producers.

**Producer-Consumers** do both. They receive events from upstream, transform them, and emit to downstream. Perfect for building pipelines.

Every GenStage process follows this lifecycle:
1. Start and connect to other stages
2. Consumer sends demand upstream
3. Producer receives demand and emits events
4. Consumer receives and processes events
5. Repeat from step 2

The demand mechanism is what makes this special. In a traditional queue, you might have:

```elixir
# Traditional approach - producer decides when to push
loop do
  job = create_job()
  Queue.push(job)  # What if queue is full?
end
```

With GenStage:

```elixir
# GenStage approach - consumer decides when to pull
def handle_demand(demand, state) do
  jobs = create_jobs(demand)  # Only create what's asked for
  {:noreply, jobs, state}
end
```

The consumer is in control. It's impossible to overwhelm a consumer because it only gets what it asked for.

## Step 4: Creating the Producer

Now for the meat of it. Let's build a producer that understands our job processing needs. Create a new file at `lib/job_processor/producer.ex`:

```elixir
defmodule JobProcessor.Producer do
  use GenStage
  require Logger

  @doc """
  Starts the producer with an initial state.

  The state can be anything, but we'll use a counter to start simple.
  """
  def start_link(initial \\ 0) do
    GenStage.start_link(__MODULE__, initial, name: __MODULE__)
  end

  @impl true
  def init(counter) do
    Logger.info("Producer starting with counter: #{counter}")
    {:producer, counter}
  end

  @impl true
  def handle_demand(demand, state) do
    Logger.info("Producer received demand for #{demand} events")

    # Generate events to fulfill demand
    events = Enum.to_list(state..(state + demand - 1))

    # Update our state
    new_state = state + demand

    # Return events and new state
    {:noreply, events, new_state}
  end
end
```

Let's dissect this line by line:

**`use GenStage`** - This macro brings in the GenStage behavior. It's like `use GenServer` but for stages. It requires us to implement certain callbacks.

**`start_link/1`** - Standard OTP pattern. We name the process after its module so we can find it easily. In production, you might want multiple producers, so you'd make the name configurable.

**`init/1`** - The crucial part: `{:producer, counter}`. The first element declares this as a producer. The second is our initial state. GenStage now knows this process will emit events when asked.

**`handle_demand/2`** - The heart of a producer. This callback fires when consumers ask for events. The arguments are:
- `demand` - How many events the consumer wants
- `state` - Our current state

The return value `{:noreply, events, new_state}` means:
- `:noreply` - We're responding to demand, not a synchronous call
- `events` - The list of events to emit (must be a list)
- `new_state` - Our updated state

### The Demand Buffer

Here's something subtle but important: GenStage maintains an internal demand buffer. If multiple consumers ask for events before you can fulfill them, GenStage aggregates the demand.

For example:
1. Consumer A asks for 10 events
2. Consumer B asks for 5 events
3. Your `handle_demand/2` receives demand for 15 events

This batching is efficient and prevents your producer from being called repeatedly for small demands.

### What if You Can't Fulfill Demand?

Sometimes you can't produce as many events as demanded. That's fine:

```elixir
def handle_demand(demand, state) do
  available = calculate_available_work()

  if available >= demand do
    events = fetch_events(demand)
    {:noreply, events, state}
  else
    # Can only partially fulfill demand
    events = fetch_events(available)
    {:noreply, events, state}
  end
end
```

GenStage tracks unfulfilled demand. If you return fewer events than demanded, it remembers. The next time you have events available, you can emit them even without new demand:

```elixir
def handle_info(:new_data_available, state) do
  events = fetch_available_events()
  {:noreply, events, state}
end
```

### Producer Patterns

Our simple counter producer is just the beginning. Real-world producers follow several patterns:

**Database Polling Producer:**
```elixir
def handle_demand(demand, state) do
  jobs = Repo.all(
    from j in Job,
    where: j.status == "pending",
    limit: ^demand,
    lock: "FOR UPDATE SKIP LOCKED"
  )

  job_ids = Enum.map(jobs, & &1.id)

  Repo.update_all(
    from(j in Job, where: j.id in ^job_ids),
    set: [status: "processing"]
  )

  {:noreply, jobs, state}
end
```

**Rate-Limited Producer:**
```elixir
def handle_demand(demand, %{rate_limit: limit} = state) do
  now = System.monotonic_time(:millisecond)
  time_passed = now - state.last_emit

  allowed = min(demand, div(time_passed * limit, 1000))

  if allowed > 0 do
    events = generate_events(allowed)
    {:noreply, events, %{state | last_emit: now}}
  else
    # Schedule retry
    Process.send_after(self(), :retry_demand, 100)
    {:noreply, [], state}
  end
end
```

**Buffering Producer:**
```elixir
def handle_demand(demand, %{buffer: buffer} = state) do
  {to_emit, remaining} = Enum.split(buffer, demand)

  if length(to_emit) < demand do
    # Buffer exhausted, try to refill
    new_events = fetch_more_events()
    all_events = to_emit ++ new_events
    {to_emit_now, to_buffer} = Enum.split(all_events, demand)
    {:noreply, to_emit_now, %{state | buffer: to_buffer}}
  else
    {:noreply, to_emit, %{state | buffer: remaining}}
  end
end
```

### Testing Your Producer

Let's make sure our producer works. Create `test/job_processor/producer_test.exs`:

```elixir
defmodule JobProcessor.ProducerTest do
  use ExUnit.Case
  alias JobProcessor.Producer

  test "producer emits events on demand" do
    {:ok, producer} = Producer.start_link(0)

    # Manually subscribe and ask for events
    {:ok, _subscription} = GenStage.sync_subscribe(self(), to: producer, max_demand: 5)

    # We should receive 5 events (0 through 4)
    assert_receive {:"$gen_consumer", {_, _}, [0, 1, 2, 3, 4]}
  end

  test "producer maintains state across demands" do
    {:ok, producer} = Producer.start_link(10)

    # First demand
    {:ok, _} = GenStage.sync_subscribe(self(), to: producer, max_demand: 3)
    assert_receive {:"$gen_consumer", {_, _}, [10, 11, 12]}

    # Second demand should continue from where we left off
    send(producer, {:"$gen_producer", {self(), nil}, {:ask, 2}})
    assert_receive {:"$gen_consumer", {_, _}, [13, 14]}
  end
end
```

Run the tests with `mix test`.

### The Power of Stateful Producers

Our producer maintains state - a simple counter. But state can be anything:

- A database connection for polling
- A buffer of pre-fetched events
- Rate limiting information
- Metrics and telemetry data

Because each producer is just an Erlang process, it's isolated. If one producer crashes, others continue. The supervisor restarts the crashed producer with a fresh state.

This is different from thread-based systems where shared state requires locks. Each producer owns its state exclusively. No locks, no race conditions, no defensive programming.

### What We've Built

Our producer is deceptively simple, but it demonstrates core principles:

1. **Demand-driven** - Only produces when asked
2. **Stateful** - Maintains its own isolated state
3. **Supervised** - Can crash and restart safely
4. **Testable** - Easy to verify behavior

In the next section, we'll build consumers that process these events. But the producer is the foundation - it controls the flow of work through our system.

# Building A Consumer

Now that we have a producer emitting events, we need something to consume them. This is where consumers come in - they're the workers that actually process the events flowing through our system.

But here's the beautiful thing about GenStage consumers: they're not passive recipients waiting for work to be thrown at them. They're active participants in the flow control. A consumer decides how much work it can handle and explicitly asks for that amount. No more, no less.

Think about how this changes the dynamics. In a traditional message queue, producers blast messages into a queue, hoping consumers can keep up. If consumers fall behind, the queue grows. If consumers are faster than expected, they sit idle waiting for work. It's a constant balancing act with lots of manual tuning.

GenStage flips this completely. Consumers know their own capacity better than anyone else. They know if they're currently processing a heavy job, if they're running low on memory, or if they're about to restart. So they ask for exactly what they can handle right now.

## The Consumer's Lifecycle

A GenStage consumer follows a simple but powerful lifecycle:

1. **Subscribe** - Connect to one or more producers
2. **Demand** - Ask for a specific number of events
3. **Receive** - Get events from producers (never more than requested)
4. **Process** - Handle each event
5. **Repeat** - Ask for more events when ready

The key insight is step 4: processing happens between demands. The consumer processes its current batch completely before asking for more. This creates natural backpressure - slow consumers automatically reduce the flow rate.

## Building Our First Consumer

Let's build a consumer that processes the events from our producer. Create a new file at `lib/job_processor/consumer.ex`:

```elixir
defmodule JobProcessor.Consumer do
  use GenStage
  require Logger

  @doc """
  Starts the consumer.

  Like producers, consumers are just GenServer-like processes.
  The state can be anything you need for processing.
  """
  def start_link(opts \\ []) do
    GenStage.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    # The key difference: we declare ourselves as a :consumer
    # and specify which producer(s) to subscribe to
    {:consumer, opts, subscribe_to: [JobProcessor.Producer]}
  end

  @impl true
  def handle_events(events, _from, state) do
    Logger.info("Consumer received #{length(events)} events")

    # Process each event
    for event <- events do
      process_event(event, state)
    end

    # Always return {:noreply, [], state} for consumers
    # The empty list means we don't emit any events (we're not a producer)
    {:noreply, [], state}
  end

  defp process_event(event, state) do
    # For now, just log what we received
    Logger.info("Processing event: #{event}")
    IO.inspect({self(), event, state}, label: "Consumer processed")
  end
end
```

## Understanding the Consumer Architecture

Let's break down what makes this consumer work:

**`use GenStage`** - Just like producers, consumers use the GenStage behavior. But the callbacks they implement are different.

**`init/1` returns `{:consumer, state, options}`** - The crucial difference from producers. The first element declares this process as a consumer. The `subscribe_to` option tells GenStage which producers to connect to.

**`handle_events/3` instead of `handle_demand/2`** - Consumers implement `handle_events/3`, which receives:
- `events` - The list of events to process
- `from` - Which producer sent these events (usually ignored)
- `state` - The consumer's current state

**The return value `{:noreply, [], state}`** - Consumers don't emit events (that's producers' job), so the events list is always empty. They just process and update their state.

## The Magic of Subscription

Notice the `subscribe_to: [JobProcessor.Producer]` option. This does several important things:

**Automatic connection** - GenStage handles finding and connecting to the producer. No manual process linking or monitoring.

**Automatic demand** - The consumer automatically asks the producer for events. By default, it requests batches of up to 1000 events, but you can tune this.

**Fault tolerance** - If the producer crashes and restarts, the consumer automatically reconnects. If the consumer crashes, it doesn't take down the producer.

**Flow control** - The consumer won't receive more events than it asks for. If it's slow processing the current batch, no new events arrive until it's ready.

## Tuning Consumer Demand

You can control how many events a consumer requests at once:

```elixir
def init(opts) do
  {:consumer, opts,
   subscribe_to: [
     {JobProcessor.Producer, min_demand: 5, max_demand: 50}
   ]}
end
```

**`min_demand`** - Don't ask for more events until we have fewer than this many
**`max_demand`** - Never ask for more than this many events at once

This creates a buffering effect. The consumer will receive events in batches between min_demand and max_demand, giving you control over throughput vs. latency tradeoffs.

For job processing, you might want smaller batches to reduce memory usage:

```elixir
subscribe_to: [
  {JobProcessor.Producer, min_demand: 1, max_demand: 10}
]
```

Or larger batches for higher throughput:

```elixir
subscribe_to: [
  {JobProcessor.Producer, min_demand: 100, max_demand: 1000}
]
```

## Why This Design Matters

The producer-consumer subscription model solves several classic distributed systems problems:

**Backpressure** - Slow consumers naturally slow down the entire pipeline. No queues overflow, no memory explosions.

**Dynamic scaling** - Add more consumers and they automatically start receiving events. Remove consumers and the remaining ones pick up the slack.

**Fault isolation** - A crashing consumer doesn't affect others. A crashing producer can be restarted without losing in-flight work.

**Observable performance** - You can see exactly where bottlenecks are by monitoring demand patterns. High accumulated demand = bottleneck downstream.

## Consumer Patterns

Real-world consumers follow several common patterns:

**Database Writing Consumer:**
```elixir
def handle_events(events, _from, state) do
  # Batch insert for efficiency
  records = Enum.map(events, &transform_event/1)
  Repo.insert_all(MyTable, records)

  {:noreply, [], state}
end
```

**HTTP API Consumer:**
```elixir
def handle_events(events, _from, state) do
  for event <- events do
    case HTTPoison.post(state.webhook_url, Jason.encode!(event)) do
      {:ok, %{status_code: 200}} -> :ok
      {:error, reason} -> Logger.error("Webhook failed: #{inspect(reason)}")
    end
  end

  {:noreply, [], state}
end
```

**File Processing Consumer:**
```elixir
def handle_events(events, _from, state) do
  for event <- events do
    file_path = "/tmp/processed_#{event.id}.json"
    File.write!(file_path, Jason.encode!(event))
  end

  {:noreply, [], state}
end
```

## Error Handling in Consumers

What happens when event processing fails? In traditional queue systems, you need complex retry logic, dead letter queues, and careful state management.

With GenStage consumers, it's simpler. If a consumer crashes while processing events, those events are simply not acknowledged. When the consumer restarts, the producer still has them and will include them in the next batch.

For more sophisticated error handling, you can catch exceptions:

```elixir
def handle_events(events, _from, state) do
  for event <- events do
    try do
      process_event(event)
    rescue
      e ->
        Logger.error("Failed to process event #{event.id}: #{inspect(e)}")
        # Could send to dead letter queue, retry later, etc.
    end
  end

  {:noreply, [], state}
end
```

But often, letting the process crash and restart is the right approach. It's simple, it clears any corrupted state, and the supervisor handles the restart automatically.

# Wiring It Together

Now we have both pieces: a producer that emits events and a consumer that processes them. But they're just modules sitting in files. We need to start them as processes and connect them.

This is where OTP's supervision trees shine. We'll add both processes to our application's supervision tree, and OTP will ensure they start in the right order and restart if they crash.

Open `lib/job_processor/application.ex` and modify the `start/2` function:

```elixir
def start(_type, _args) do
  children = [
    # Start the Producer first
    JobProcessor.Producer,

    # Then start the Consumer
    # The consumer will automatically connect to the producer
    JobProcessor.Consumer,

    # Other children like Ecto, Phoenix endpoint, etc.
    JobProcessorWeb.Endpoint
  ]

  opts = [strategy: :one_for_one, name: JobProcessor.Supervisor]
  Supervisor.start_link(children, opts)
end
```

That's it! The supervision tree will:

1. Start the producer
2. Start the consumer
3. The consumer automatically subscribes to the producer
4. Events start flowing immediately

## Why This Supervision Strategy Works

The `:one_for_one` strategy means if one process crashes, only that process is restarted. This is perfect for our producer-consumer setup:

**Producer crashes** - The consumer notices the connection is lost and waits. When the supervisor restarts the producer, the consumer automatically reconnects.

**Consumer crashes** - The producer keeps running, just stops emitting events. When the supervisor restarts the consumer, it reconnects and processing resumes.

This is fault isolation in action. Problems in one part of the system don't cascade to other parts.

## Testing the Connection

Let's see our producer and consumer working together. Start the application:

```
mix phx.server
```

You should see logs showing the consumer processing events from the producer. Each event will be displayed with the process ID, event number, and state - something like this:

```
Consumer processed: {#PID<0.234.0>, 0, []}
Consumer processed: {#PID<0.234.0>, 1, []}
Consumer processed: {#PID<0.234.0>, 2, []}
Consumer processed: {#PID<0.234.0>, 3, []}
Consumer processed: {#PID<0.234.0>, 4, []}
...
```

Notice something important: the same PID processes every event. This is because we have a single consumer. Our counter increments predictably from 0, 1, 2, 3, 4... and all events flow to the same process.

## The Single Consumer Scenario

With one consumer, we get:
- **Predictable ordering** - Events are processed in the exact order they're generated
- **Sequential processing** - Each event is fully processed before the next one begins
- **Simple state management** - Only one process to reason about
- **Potential bottleneck** - If processing is slow, the entire pipeline slows down

```
Single Consumer Pattern: Sequential Processing

[Producer] ──→ ⓪ ──→ ① ──→ ② ──→ ③ ──→ ④ ──→ ⑤ ──→ [Consumer]
(Emits 0,1,2,3,4...)                                    (Processes Sequentially)

Timeline:
t0: ████████ Process Event 0
t1:         ████████ Process Event 1  
t2:                 ████████ Process Event 2
t3:                         ░░░░░░░░░░░░░░░░░░░ Events 3,4,5... waiting

Key Characteristics:
✓ Predictable ordering - Events processed in exact sequence
✓ Sequential processing - One event completes before next begins  
✓ Simple state management - Single process to track
⚠ Potential bottleneck - Slow processing blocks entire pipeline
```

This is perfect for scenarios where order matters or when you're just getting started. But what happens when we add more consumers?

## Scaling to Multiple Consumers

Let's see what happens with multiple consumers. Add this to your supervision tree in `lib/job_processor/application.ex`:

```elixir
def start(_type, _args) do
  children = [
    # Start the Producer first
    JobProcessor.Producer,

    # Start multiple consumers
    {JobProcessor.Consumer, [id: :consumer_1]},
    {JobProcessor.Consumer, [id: :consumer_2]},
    {JobProcessor.Consumer, [id: :consumer_3]},

    # Other children
    JobProcessorWeb.Endpoint
  ]

  opts = [strategy: :one_for_one, name: JobProcessor.Supervisor]
  Supervisor.start_link(children, opts)
end
```

Now restart your application and watch the logs:

```
Consumer processed: {#PID<0.234.0>, 0, []}
Consumer processed: {#PID<0.234.0>, 1, []}
Consumer processed: {#PID<0.235.0>, 2, []}
Consumer processed: {#PID<0.236.0>, 3, []}
Consumer processed: {#PID<0.234.0>, 4, []}
Consumer processed: {#PID<0.235.0>, 5, []}
...
```

Notice the different PIDs! Events are now distributed across multiple consumer processes. The distribution depends on which consumer asks for work first and how fast each consumer processes its events.

```
Multiple Consumer Pattern: Parallel Processing with Load Balancing

                    ┌──→ Consumer 1 (PID <0.234.0>) ─→ Events: 0, 1, 4...
                    │    ↑ demand
[Producer] ─────────┼──→ Consumer 2 (PID <0.235.0>) ─→ Events: 2, 5, 8...  
(First-Come-       │    ↑ demand
First-Served)      └──→ Consumer 3 (PID <0.236.0>) ─→ Events: 3, 6, 7...
                         ↑ demand

Timeline: Parallel Processing
Consumer 1: ██████████ Event 0    ████████ Event 1    ████████████ Event 4
Consumer 2:     ████████████ Event 2    ██████████ Event 5
Consumer 3:         ████████ Event 3    ████████████ Event 6

✓ Benefits:                              ⚠ Challenges:
• Higher throughput - parallel          • No ordering guarantees  
• Fault tolerance - others continue     • Shared resource contention
• Natural load balancing               • Debugging complexity
• Better resource utilization         • Potential race conditions
```

## Understanding Event Distribution

GenStage's default dispatcher (DemandDispatcher) uses a "first-come, first-served" approach:

1. Consumer A finishes its current batch and asks for 10 more events
2. Producer sends events 0-9 to Consumer A
3. Consumer B asks for 10 events
4. Producer sends events 10-19 to Consumer B
5. Consumer A finishes and asks for more, gets events 20-29

This creates natural load balancing - faster consumers get more work. If Consumer A is processing heavy jobs slowly, Consumer B and C will pick up the slack.

## The Trade-offs

**Benefits of Multiple Consumers:**
- **Throughput** - More work gets done in parallel
- **Fault tolerance** - If one consumer crashes, others continue
- **Natural load balancing** - Fast consumers get more work
- **Resource utilization** - Better use of multi-core systems

**Challenges:**
- **No ordering guarantees** - Event 5 might finish before event 3
- **Shared resources** - Multiple consumers might compete for database connections
- **Debugging complexity** - Multiple processes to track

## Different Distribution Strategies

You can change how events are distributed by modifying the producer's dispatcher. Add this to your producer's `init/1` function:

```elixir
def init(counter) do
  Logger.info("Producer starting with counter: #{counter}")
  {:producer, counter, dispatcher: GenStage.BroadcastDispatcher}
end
```

Now restart and watch what happens:

```
Consumer processed: {#PID<0.234.0>, 0, []}
Consumer processed: {#PID<0.235.0>, 0, []}
Consumer processed: {#PID<0.236.0>, 0, []}
Consumer processed: {#PID<0.234.0>, 1, []}
Consumer processed: {#PID<0.235.0>, 1, []}
Consumer processed: {#PID<0.236.0>, 1, []}
...
```

With BroadcastDispatcher, every consumer receives every event! This is useful for scenarios like:
- Multiple consumers writing to different databases
- One consumer processing events, another collecting metrics
- Broadcasting notifications to multiple systems

```
BroadcastDispatcher: Every Consumer Receives Every Event

                    ┌─→ Database Writer (PID <0.234.0>) ─→ Events: 0, 1, 2, 3...
                    │
[Producer] ═══━━━━━━┼─→ Metrics Collector (PID <0.235.0>) ─→ Events: 0, 1, 2, 3...
(Broadcasting)     │
                    └─→ Notification Service (PID <0.236.0>) ─→ Events: 0, 1, 2, 3...

Timeline: All Consumers Process Same Events Simultaneously
Database Writer:     ████████ Event 0    ████████ Event 1    ████████ Event 2
Metrics Collector:   ████████ Event 0    ████████ Event 1    ████████ Event 2  
Notification Service:████████ Event 0    ████████ Event 1    ████████ Event 2

🔄 Broadcasting Use Cases:
• Multiple databases - Each consumer writes to different database
• Parallel processing - One processes data, another collects metrics  
• Notification fanout - Broadcasting alerts to multiple services
• Audit trails - Simultaneous logging to multiple destinations

Key Differences from Load Balancing:
✓ Every consumer gets EVERY event (no distribution)
✓ Perfect for parallel processing different aspects
✓ Higher total throughput but more resource usage
⚠ N times more processing (N = number of consumers)
```

But we're still just processing numbers. In the next section, we'll replace our simple counter with a real job processing system that can execute arbitrary code.

# From Toy Examples to Real Job Processing

We've built a solid foundation with our producer-consumer setup, but we're still just processing incrementing numbers. That's useful for understanding the mechanics, but real job processing needs persistent storage, job queuing, and the ability to execute arbitrary code.

This is where things get interesting. We're going to transform our simple counter into a full job processing system that can serialize function calls, store them in a database, and execute them across multiple workers. Think of it as building your own mini-Sidekiq, but with GenStage's elegant backpressure handling.

## Why We Need a Database

Right now, our producer generates events from memory (a simple counter). But real job processors need persistence for several reasons:

**Durability** - Jobs shouldn't disappear if the system restarts. When you queue a job to send an email, you expect it to survive server reboots.

**Coordination** - Multiple producer processes might be running across different servers. They need a shared source of truth for what work exists.

**Status tracking** - Jobs have lifecycles: queued, running, completed, failed. You need to track this state somewhere.

**Debugging and monitoring** - When jobs fail, you need to see what went wrong and potentially retry them.

The database becomes our job queue's persistent storage layer, but GenStage handles all the flow control and distribution logic.

## Setting Up Our Job Storage

Since we're using Phoenix, we already have Ecto configured. But we need to set up our job storage table. The beauty of Elixir's job processing is that we can serialize entire function calls as binary data using the Erlang Term Format.

Let's create a migration for our jobs table:

```
mix ecto.gen.migration create_jobs
```

Now edit the migration file:

```elixir
defmodule JobProcessor.Repo.Migrations.CreateJobs do
  use Ecto.Migration

  def change do
    create table(:jobs) do
      add :status, :string, null: false, default: "queued"
      add :payload, :binary, null: false
      add :attempts, :integer, default: 0
      add :max_attempts, :integer, default: 3
      add :scheduled_at, :utc_datetime
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :error_message, :text

      timestamps()
    end

    create index(:jobs, [:status])
    create index(:jobs, [:scheduled_at])
    create index(:jobs, [:status, :scheduled_at])
  end
end
```

This gives us a robust job storage system:

- **status** - Track job lifecycle (queued, running, completed, failed)
- **payload** - The serialized function call
- **attempts/max_attempts** - Retry logic
- **scheduled_at** - Support for delayed jobs
- **Timestamps** - Monitor performance and debug issues

Run the migration:

```
mix ecto.migrate
```

## Modeling Jobs

Let's create an Ecto schema for our jobs. Create `lib/job_processor/job.ex`:

```elixir
defmodule JobProcessor.Job do
  use Ecto.Schema
  import Ecto.Changeset

  schema "jobs" do
    field :status, :string, default: "queued"
    field :payload, :binary
    field :attempts, :integer, default: 0
    field :max_attempts, :integer, default: 3
    field :scheduled_at, :utc_datetime
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :error_message, :string

    timestamps()
  end

  def changeset(job, attrs) do
    job
    |> cast(attrs, [:status, :payload, :attempts, :max_attempts,
                    :scheduled_at, :started_at, :completed_at, :error_message])
    |> validate_required([:payload])
    |> validate_inclusion(:status, ["queued", "running", "completed", "failed"])
  end

  @doc """
  Serialize a function call into a job payload.

  This is where the magic happens - we can serialize any module, function,
  and arguments into binary data that can be stored and executed later.
  """
  def encode_job(module, function, args) do
    {module, function, args} |> :erlang.term_to_binary()
  end

  @doc """
  Deserialize a job payload back into a function call.
  """
  def decode_job(payload) do
    :erlang.binary_to_term(payload)
  end
end
```

## Building the Job Queue Interface

Now we need an interface for interacting with jobs. This is where we abstract the database operations and provide a clean API for enqueueing and processing jobs. Create `lib/job_processor/job_queue.ex`:

```elixir
defmodule JobProcessor.JobQueue do
  import Ecto.Query
  alias JobProcessor.{Repo, Job}

  @doc """
  Enqueue a job for processing.

  This is the public API that applications use to submit work.
  """
  def enqueue(module, function, args, opts \\ []) do
    payload = Job.encode_job(module, function, args)

    attrs = %{
      payload: payload,
      max_attempts: Keyword.get(opts, :max_attempts, 3),
      scheduled_at: Keyword.get(opts, :scheduled_at, DateTime.utc_now())
    }

    %Job{}
    |> Job.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Fetch available jobs for processing.

  This is called by our GenStage producer to get work.
  Uses FOR UPDATE SKIP LOCKED to avoid race conditions.
  """
  def fetch_jobs(limit) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      # Find available jobs
      job_ids =
        from(j in Job,
          where: j.status == "queued" and j.scheduled_at <= ^now,
          limit: ^limit,
          select: j.id,
          lock: "FOR UPDATE SKIP LOCKED"
        )
        |> Repo.all()

      # Mark them as running and return the full job data
      {count, jobs} =
        from(j in Job, where: j.id in ^job_ids)
        |> Repo.update_all(
          [set: [status: "running", started_at: DateTime.utc_now()]],
          returning: [:id, :payload, :attempts, :max_attempts]
        )

      {count, jobs}
    end)
  end

  @doc """
  Mark a job as completed successfully.
  """
  def complete_job(job_id) do
    from(j in Job, where: j.id == ^job_id)
    |> Repo.update_all(
      set: [status: "completed", completed_at: DateTime.utc_now()]
    )
  end

  @doc """
  Mark a job as failed and handle retry logic.
  """
  def fail_job(job_id, error_message, attempts \\ 1) do
    job = Repo.get!(Job, job_id)

    if attempts >= job.max_attempts do
      # Permanently failed
      from(j in Job, where: j.id == ^job_id)
      |> Repo.update_all(
        set: [
          status: "failed",
          error_message: error_message,
          attempts: attempts,
          completed_at: DateTime.utc_now()
        ]
      )
    else
      # Retry later
      retry_at = DateTime.add(DateTime.utc_now(), 60 * attempts, :second)

      from(j in Job, where: j.id == ^job_id)
      |> Repo.update_all(
        set: [
          status: "queued",
          error_message: error_message,
          attempts: attempts,
          scheduled_at: retry_at
        ]
      )
    end
  end
end
```

## The Power of FOR UPDATE SKIP LOCKED

Notice that crucial line: `lock: "FOR UPDATE SKIP LOCKED"`. This is a PostgreSQL feature that's essential for job processing systems.

Here's what happens without it:
1. Consumer A queries for jobs, gets job #123
2. Consumer B queries for jobs, gets the same job #123
3. Both consumers try to process job #123 simultaneously
4. Chaos ensues

With `FOR UPDATE SKIP LOCKED`:
1. Consumer A queries for jobs, locks job #123
2. Consumer B queries for jobs, skips locked job #123, gets job #124
3. Each job is processed exactly once
4. No race conditions, no duplicate processing

This is why PostgreSQL (and similar databases) are preferred for job processing systems. The database handles the coordination for us.

## Updating Our Producer

Now we can update our producer to fetch real jobs from the database instead of generating counter events. Update `lib/job_processor/producer.ex`:

```elixir
defmodule JobProcessor.Producer do
  use GenStage
  require Logger
  alias JobProcessor.JobQueue

  def start_link(_opts) do
    GenStage.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    Logger.info("Job Producer starting")
    {:producer, %{}, dispatcher: GenStage.DemandDispatcher}
  end

  @impl true
  def handle_demand(demand, state) when demand > 0 do
    Logger.info("Producer received demand for #{demand} jobs")

    case JobQueue.fetch_jobs(demand) do
      {:ok, {count, jobs}} when count > 0 ->
        Logger.info("Fetched #{count} jobs from database")
        {:noreply, jobs, state}

      {:ok, {0, []}} ->
        # No jobs available, schedule a check for later
        Process.send_after(self(), :check_for_jobs, 1000)
        {:noreply, [], state}

      {:error, reason} ->
        Logger.error("Failed to fetch jobs: #{inspect(reason)}")
        {:noreply, [], state}
    end
  end

  @impl true
  def handle_info(:check_for_jobs, state) do
    # This allows us to produce events even when there's no pending demand
    # if jobs become available
    case JobQueue.fetch_jobs(10) do
      {:ok, {count, jobs}} when count > 0 ->
        {:noreply, jobs, state}
      _ ->
        Process.send_after(self(), :check_for_jobs, 1000)
        {:noreply, [], state}
    end
  end
end
```

## Understanding the Producer's Evolution

Our producer has evolved significantly:

**Database-driven** - Instead of generating events from memory, we fetch them from persistent storage

**Handles empty queues gracefully** - When no jobs are available, we schedule a check for later instead of blocking

**Error handling** - Database operations can fail, so we handle those cases

**Polling mechanism** - The `:check_for_jobs` message lets us produce events even when there's no pending demand

This polling approach works well for most job processing systems. For higher throughput systems, you could use PostgreSQL's LISTEN/NOTIFY to get push notifications when new jobs arrive.

## Updating Our Consumer

Now our consumer needs to execute real job payloads instead of just logging numbers. Update `lib/job_processor/consumer.ex`:

```elixir
defmodule JobProcessor.Consumer do
  use GenStage
  require Logger
  alias JobProcessor.{Job, JobQueue}

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    {:consumer, opts, subscribe_to: [JobProcessor.Producer]}
  end

  @impl true
  def handle_events(jobs, _from, state) do
    Logger.info("Consumer received #{length(jobs)} jobs")

    for job <- jobs do
      execute_job(job)
    end

    {:noreply, [], state}
  end

  defp execute_job(%{id: job_id, payload: payload, attempts: attempts}) do
    try do
      {module, function, args} = Job.decode_job(payload)

      Logger.info("Executing job #{job_id}: #{module}.#{function}")

      # Execute the job
      result = apply(module, function, args)

      # Mark as completed
      JobQueue.complete_job(job_id)

      Logger.info("Job #{job_id} completed successfully")

      result
    rescue
      error ->
        error_message = Exception.format(:error, error, __STACKTRACE__)
        Logger.error("Job #{job_id} failed: #{error_message}")

        # Mark as failed (with retry logic)
        JobQueue.fail_job(job_id, error_message, attempts + 1)
    end
  end
end
```

## The Magic of Code Serialization

The real power of this system is in those two lines:

```elixir
{module, function, args} = Job.decode_job(payload)
result = apply(module, function, args)
```

We're deserializing a function call that was stored as binary data and executing it. This means you can queue any function call:

```elixir
# Send an email
JobQueue.enqueue(MyApp.Mailer, :send_welcome_email, [user_id: 123])

# Process an image
JobQueue.enqueue(MyApp.ImageProcessor, :resize_image, ["/path/to/image.jpg", 300, 200])

# Call an API
JobQueue.enqueue(MyApp.ApiClient, :sync_user_data, [user_id: 456])

# Even complex data structures
JobQueue.enqueue(MyApp.ReportGenerator, :generate_report, [%{
  user_id: 789,
  date_range: Date.range(~D[2024-01-01], ~D[2024-01-31]),
  format: :pdf
}])
```

Each of these becomes a row in the database, gets picked up by our GenStage producer, distributed to available consumers, and executed. The serialization handles all the complex data structures automatically.

## What We've Built

We now have a complete job processing system with:

- **Persistent storage** - Jobs survive restarts
- **Automatic retries** - Failed jobs are retried with exponential backoff
- **Concurrent processing** - Multiple consumers process jobs in parallel
- **Backpressure handling** - GenStage ensures consumers aren't overwhelmed
- **Race condition prevention** - Database locking ensures each job runs exactly once
- **Delayed jobs** - Support for scheduling jobs to run later
- **Error tracking** - Failed jobs are logged with error messages

And the beautiful part? GenStage handles all the complex coordination. We just focus on the business logic of our jobs.

## Testing Our Job System

Let's create a simple job to test our system. Add this to `lib/job_processor/test_job.ex`:

```elixir
defmodule JobProcessor.TestJob do
  require Logger

  def hello(name) do
    Logger.info("Hello, #{name}!")
    Process.sleep(1000)  # Simulate some work
    "Greeted #{name}"
  end

  def failing_job do
    Logger.info("This job will fail...")
    raise "Intentional failure for testing"
  end

  def heavy_job(duration_ms) do
    Logger.info("Starting heavy job for #{duration_ms}ms")
    Process.sleep(duration_ms)
    Logger.info("Heavy job completed")
    "Completed heavy work"
  end
end
```

Now you can queue jobs from the console:

```elixir
iex -S mix

# Queue a simple job
JobProcessor.JobQueue.enqueue(JobProcessor.TestJob, :hello, ["World"])

# Queue a failing job (to test retry logic)
JobProcessor.JobQueue.enqueue(JobProcessor.TestJob, :failing_job, [])

# Queue multiple jobs to see parallel processing
for i <- 1..10 do
  JobProcessor.JobQueue.enqueue(JobProcessor.TestJob, :hello, ["Person #{i}"])
end
```

Watch the logs to see jobs being processed, failures being retried, and the natural load balancing across multiple consumers.

We've transformed our simple counter example into a production-ready job processing system. The core GenStage concepts remained the same, but now we're processing real work with persistence, error handling, and retry logic.