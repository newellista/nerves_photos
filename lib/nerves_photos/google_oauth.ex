defmodule NervesPhotos.GoogleOAuth do
  @moduledoc false

  @auth_endpoint "https://accounts.google.com/o/oauth2/v2/auth"
  @token_endpoint "https://oauth2.googleapis.com/token"
  @scope "https://www.googleapis.com/auth/photoslibrary.readonly"

  def authorization_url(client_id, redirect_uri, state) do
    query =
      URI.encode_query([
        {"response_type", "code"},
        {"client_id", client_id},
        {"redirect_uri", redirect_uri},
        {"scope", @scope},
        {"access_type", "offline"},
        {"prompt", "consent"},
        {"state", state}
      ])

    @auth_endpoint <> "?" <> query
  end

  def exchange_code(client_id, client_secret, code, redirect_uri, opts \\ []) do
    req = build_req(opts)

    case Req.post(req,
           url: @token_endpoint,
           form: [
             code: code,
             client_id: client_id,
             client_secret: client_secret,
             redirect_uri: redirect_uri,
             grant_type: "authorization_code"
           ]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, %{access_token: body["access_token"], refresh_token: body["refresh_token"]}}

      {:ok, %{body: %{"error" => "invalid_grant"}}} ->
        {:error, :invalid_grant}

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
