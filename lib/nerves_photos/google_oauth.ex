defmodule NervesPhotos.GoogleOAuth do
  @moduledoc false

  @device_endpoint "https://oauth2.googleapis.com/device/code"
  @token_endpoint "https://oauth2.googleapis.com/token"
  @scope "https://www.googleapis.com/auth/photoslibrary.readonly"

  def device_authorize(client_id, opts \\ []) do
    req = build_req(opts)

    case Req.post(req, url: @device_endpoint, form: [client_id: client_id, scope: @scope]) do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           device_code: body["device_code"],
           user_code: body["user_code"],
           verification_url: body["verification_url"],
           expires_in: body["expires_in"],
           interval: body["interval"]
         }}

      {:ok, %{body: body}} ->
        {:error, body["error"]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def poll_token(client_id, client_secret, device_code, opts \\ []) do
    req = build_req(opts)

    case Req.post(req,
           url: @token_endpoint,
           form: [
             client_id: client_id,
             client_secret: client_secret,
             device_code: device_code,
             grant_type: "urn:ietf:params:oauth:grant-type:device_code"
           ]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, %{access_token: body["access_token"], refresh_token: body["refresh_token"]}}

      {:ok, %{body: %{"error" => err}}} when err in ["authorization_pending", "slow_down"] ->
        :pending

      {:ok, %{body: body}} ->
        {:error, body["error"]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def refresh_access_token(client_id, client_secret, refresh_token, opts \\ []) do
    req = build_req(opts)

    case Req.post(req,
           url: @token_endpoint,
           form: [
             client_id: client_id,
             client_secret: client_secret,
             refresh_token: refresh_token,
             grant_type: "refresh_token"
           ]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body["access_token"]}

      {:ok, %{body: %{"error" => "invalid_grant"}}} ->
        {:error, :invalid_grant}

      {:ok, %{body: body}} ->
        {:error, body["error"]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_req(opts) do
    req_options = Keyword.get(opts, :req_options, [])
    Req.new(req_options)
  end
end
