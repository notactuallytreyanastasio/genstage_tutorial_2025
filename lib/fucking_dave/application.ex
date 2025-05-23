defmodule FuckingDave.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FuckingDaveWeb.Telemetry,
      FuckingDave.Repo,
      {DNSCluster, query: Application.get_env(:fucking_dave, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: FuckingDave.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: FuckingDave.Finch},
      JobProcessor.Producer,
      JobProcessor.Consumer,

      FuckingDaveWeb.Endpoint
    ] # ++ consumer_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FuckingDave.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FuckingDaveWeb.Endpoint.config_change(changed, removed)
    :ok
  end

    # Dynamic consumer generation based on system capabilities
  # defp consumer_children do
  #   # Create 2 consumers per scheduler for better concurrency
  #   consumer_count = System.schedulers_online() * 2

  #   for id <- 1..consumer_count do
  #     Supervisor.child_spec(
  #       {JobProcessor.Consumer, 0},
  #       id: :"consumer_#{id}"
  #     )
  #   end
  # end
end
