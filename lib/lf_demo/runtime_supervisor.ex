defmodule LfDemo.RuntimeSupervisor do
  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    children = [
      {LfDemo.Store, Keyword.get(opts, :store_options, name: LfDemo.Store)},
      {Task.Supervisor, Keyword.get(opts, :task_options, name: LfDemo.TaskSupervisor)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
