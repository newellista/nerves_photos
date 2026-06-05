defmodule NervesPhotos.GoogleOAuthTest do
  use ExUnit.Case, async: false
  alias NervesPhotos.GoogleOAuth

  @client_id "test-client-id"
  @client_secret "test-client-secret"
  @redirect_uri "http://localhost:4000/settings/oauth_callback"

  describe "authorization_url/3" do
    test "returns URL with correct params" do
      url = GoogleOAuth.authorization_url(@client_id, @redirect_uri, "STATE123")
      uri = URI.parse(url)
      params = URI.decode_query(uri.query)

      assert uri.scheme == "https"
      assert uri.host == "accounts.google.com"
      assert params["response_type"] == "code"
      assert params["client_id"] == @client_id
      assert params["redirect_uri"] == @redirect_uri
      assert params["scope"] == "https://www.googleapis.com/auth/photoslibrary.readonly"
      assert params["access_type"] == "offline"
      assert params["prompt"] == "consent"
      assert params["state"] == "STATE123"
    end
  end

  describe "exchange_code/5" do
    test "returns tokens on success" do
      Req.Test.stub(GoogleOAuthExchangeTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "ACCESS",
            "refresh_token" => "REFRESH",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          })
        )
      end)

      opts = [req_options: [plug: {Req.Test, GoogleOAuthExchangeTest}]]

      assert {:ok, tokens} =
               GoogleOAuth.exchange_code(@client_id, @client_secret, "CODE", @redirect_uri, opts)

      assert tokens.access_token == "ACCESS"
      assert tokens.refresh_token == "REFRESH"
    end

    test "returns :invalid_grant when code is already used or expired" do
      Req.Test.stub(GoogleOAuthExchangeErrTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
      end)

      opts = [req_options: [plug: {Req.Test, GoogleOAuthExchangeErrTest}]]

      assert {:error, :invalid_grant} =
               GoogleOAuth.exchange_code(@client_id, @client_secret, "CODE", @redirect_uri, opts)
    end
  end

  describe "refresh_access_token/4" do
    test "returns fresh access_token on success" do
      Req.Test.stub(GoogleOAuthRefreshTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "NEW_ACCESS",
            "expires_in" => 3600
          })
        )
      end)

      opts = [req_options: [plug: {Req.Test, GoogleOAuthRefreshTest}]]

      assert {:ok, "NEW_ACCESS"} =
               GoogleOAuth.refresh_access_token(@client_id, @client_secret, "REFRESH", opts)
    end

    test "returns error when refresh token is revoked" do
      Req.Test.stub(GoogleOAuthRefreshErrTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
      end)

      opts = [req_options: [plug: {Req.Test, GoogleOAuthRefreshErrTest}]]

      assert {:error, :invalid_grant} =
               GoogleOAuth.refresh_access_token(@client_id, @client_secret, "REFRESH", opts)
    end
  end
end
