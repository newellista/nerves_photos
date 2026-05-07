defmodule NervesPhotos.PhotoSource do
  @moduledoc false

  @callback list_assets(config :: map()) ::
              {:ok, [{source_id :: String.t(), metadata :: map()}]} | {:error, term()}

  @callback fetch_image(source_id :: String.t(), config :: map()) ::
              {:ok, binary()} | {:error, term()}
end
