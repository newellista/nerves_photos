defmodule NervesPhotos.GoogleOAuthTest do
  use ExUnit.Case, async: false
  alias NervesPhotos.GoogleOAuth

  @client_id "test-client-id"
  @client_secret "test-client-secret"

  describe "device_authorize/2" do
    test "returns device_code and user_code on success" do
      Req.Test.stub(GoogleOAuthDeviceTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "device_code" => "DEV_CODE",
            "user_code" => "ABCD-1234",
            "verification_url" => "https://google.com/device",
            "expires_in" => 1800,
            "interval" => 5
          })
        )
      end)

      opts = [req_options: [plug: {Req.Test, GoogleOAuthDeviceTest}]]
      assert {:ok, result} = GoogleOAuth.device_authorize(@client_id, opts)
      assert result.device_code == "DEV_CODE"
      assert result.user_code == "ABCD-1234"
      assert result.verification_url == "https://google.com/device"
      assert result.interval == 5
    end

    test "returns error on failure" do
      Req.Test.stub(GoogleOAuthDeviceErrTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "invalid_client"}))
      end)

      opts = [req_options: [plug: {Req.Test, GoogleOAuthDeviceErrTest}]]
      assert {:error, _} = GoogleOAuth.device_authorize(@client_id, opts)
    end
  end

  describe "poll_token/4" do
    test "returns {:ok, tokens} when user completes auth" do
      Req.Test.stub(GoogleOAuthPollSuccessTest, fn conn ->
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

      opts = [req_options: [plug: {Req.Test, GoogleOAuthPollSuccessTest}]]
      assert {:ok, tokens} = GoogleOAuth.poll_token(@client_id, @client_secret, "DEV_CODE", opts)
      assert tokens.access_token == "ACCESS"
      assert tokens.refresh_token == "REFRESH"
    end

    test "returns :pending when user has not yet authorized" do
      Req.Test.stub(GoogleOAuthPollPendingTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(428, Jason.encode!(%{"error" => "authorization_pending"}))
      end)

      opts = [req_options: [plug: {Req.Test, GoogleOAuthPollPendingTest}]]
      assert :pending = GoogleOAuth.poll_token(@client_id, @client_secret, "DEV_CODE", opts)
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
