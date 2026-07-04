defmodule Harness.NotifyTest do
  use ExUnit.Case, async: false

  alias Harness.Notify

  setup do
    Notify.TestBackend.subscribe()
    :ok
  end

  test "delivers a titled notification to the backend" do
    Notify.notify(:pr_opened, "PR opened for o/r#1")
    assert_receive {:notify, :pr_opened, "Harness · PR opened", "PR opened for o/r#1"}
  end

  test "each event carries its own human title" do
    for {event, title} <- [
          {:plan_ready, "Plan ready"},
          {:run_failed, "Run failed"},
          {:gate_tripped, "Gate tripped"},
          {:budget_warning, "Budget warning"}
        ] do
      Notify.notify(event, "msg")
      assert_receive {:notify, ^event, full_title, "msg"}
      assert full_title == "Harness · #{title}"
    end
  end

  test "a backend crash never propagates to the caller" do
    defmodule Boom do
      @behaviour Harness.Notify.Backend
      def deliver(_, _, _, _), do: raise("kaboom")
    end

    Application.put_env(:harness, :notify_backend, Boom)
    on_exit(fn -> Application.put_env(:harness, :notify_backend, Notify.TestBackend) end)

    assert :ok = Notify.notify(:run_failed, "should not raise")
  end
end
