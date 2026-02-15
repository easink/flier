defmodule FlierTest do
  use ExUnit.Case
  doctest Flier

  test "greets the world" do
    assert Flier.hello() == :world
  end
end
