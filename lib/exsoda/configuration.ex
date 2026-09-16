defmodule Exsoda.Configuration do
  defstruct id: nil, name: nil, type: nil, properties: nil, domainCName: nil

  defmodule Property do
    defstruct name: nil, value: nil
  end
end
