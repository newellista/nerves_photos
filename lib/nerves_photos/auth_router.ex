defmodule NervesPhotos.AuthRouter do
  @moduledoc false
  use Plug.Router
  import Plug.Conn

  plug(:match)
  plug(:dispatch)

  get "/login" do
    users = NervesPhotos.UserStore.all()
    send_resp(conn, 200, render_login(users == [], nil))
  end

  post "/login" do
    params = conn.body_params
    username = params["username"] || ""
    password = params["password"] || ""
    users = NervesPhotos.UserStore.all()

    if users == [] do
      password_confirm = params["password_confirm"] || ""

      if password != password_confirm do
        send_resp(conn, 200, render_login(true, "Passwords do not match"))
      else
        case NervesPhotos.User.new(username, password, "admin") do
          {:ok, user} ->
            NervesPhotos.UserStore.put(username, user)

            conn
            |> put_session("current_user", %{username: username, role: :admin})
            |> configure_session(renew: true)
            |> put_resp_header("location", "/settings")
            |> send_resp(302, "")

          {:error, reason} ->
            send_resp(conn, 200, render_login(true, reason))
        end
      end
    else
      case NervesPhotos.UserStore.get(username) do
        nil ->
          send_resp(conn, 200, render_login(false, "Invalid username or password"))

        user ->
          if NervesPhotos.User.verify_password(user, password) do
            role = String.to_existing_atom(user.role)

            conn
            |> put_session("current_user", %{username: username, role: role})
            |> configure_session(renew: true)
            |> put_resp_header("location", "/settings")
            |> send_resp(302, "")
          else
            send_resp(conn, 200, render_login(false, "Invalid username or password"))
          end
      end
    end
  end

  post "/logout" do
    conn
    |> configure_session(drop: true)
    |> put_resp_header("location", "/login")
    |> send_resp(302, "")
  end

  get "/" do
    case Bodyguard.permit(NervesPhotos.Policy, :manage_users, conn.assigns.current_user) do
      :ok ->
        users = NervesPhotos.UserStore.all()
        send_resp(conn, 200, render_users_page(users, conn.assigns.current_user))

      {:error, _} ->
        send_resp(conn, 403, "Forbidden")
    end
  end

  post "/" do
    case Bodyguard.permit(NervesPhotos.Policy, :manage_users, conn.assigns.current_user) do
      :ok ->
        params = conn.body_params
        username = params["username"] || ""
        password = params["password"] || ""
        role = params["role"] || ""

        case NervesPhotos.User.new(username, password, role) do
          {:ok, user} ->
            NervesPhotos.UserStore.put(username, user)

            conn
            |> put_resp_header("location", "/settings/users")
            |> send_resp(302, "")

          {:error, reason} ->
            users = NervesPhotos.UserStore.all()
            send_resp(conn, 422, render_users_page(users, conn.assigns.current_user, reason))
        end

      {:error, _} ->
        send_resp(conn, 403, "Forbidden")
    end
  end

  delete "/:username" do
    case Bodyguard.permit(NervesPhotos.Policy, :manage_users, conn.assigns.current_user) do
      :ok ->
        NervesPhotos.UserStore.delete(conn.params["username"])

        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(200, Jason.encode!(%{ok: true}))

      {:error, _} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(403, Jason.encode!(%{error: "forbidden"}))
    end
  end

  patch "/:username/role" do
    case Bodyguard.permit(NervesPhotos.Policy, :manage_users, conn.assigns.current_user) do
      :ok ->
        username = conn.params["username"]
        new_role = conn.body_params["role"] || ""

        if new_role in ~w(admin editor) do
          case NervesPhotos.UserStore.get(username) do
            nil ->
              conn
              |> put_resp_header("content-type", "application/json")
              |> send_resp(404, Jason.encode!(%{error: "user not found"}))

            user ->
              NervesPhotos.UserStore.put(username, %{user | role: new_role})

              conn
              |> put_resp_header("content-type", "application/json")
              |> send_resp(200, Jason.encode!(%{ok: true}))
          end
        else
          conn
          |> put_resp_header("content-type", "application/json")
          |> send_resp(422, Jason.encode!(%{error: "invalid role"}))
        end

      {:error, _} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(403, Jason.encode!(%{error: "forbidden"}))
    end
  end

  defp render_login(bootstrap?, error) do
    csrf = Plug.CSRFProtection.get_csrf_token()
    title = if bootstrap?, do: "Create First Admin Account", else: "Sign In"

    error_html =
      if error,
        do: ~s(<div class="error">#{Plug.HTML.html_escape(error)}</div>),
        else: ""

    password_confirm_html =
      if bootstrap? do
        """
        <label>Confirm Password
          <input type="password" name="password_confirm" autocomplete="new-password">
        </label>
        """
      else
        ""
      end

    btn_label = if bootstrap?, do: "Create Account", else: "Sign In"

    """
    <!DOCTYPE html>
    <html>
    <head>
      <title>NervesPhotos &mdash; #{title}</title>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: sans-serif; display: flex; align-items: center;
               justify-content: center; min-height: 100vh; background: #f8f9fa; }
        .card { background: white; padding: 32px; border-radius: 8px;
                box-shadow: 0 1px 3px rgba(0,0,0,0.12); width: 320px; }
        h1 { font-size: 18px; color: #1e293b; margin-bottom: 20px; }
        label { display: block; margin-top: 16px; font-size: 13px; color: #64748b;
                text-transform: uppercase; letter-spacing: 0.5px; }
        input { width: 100%; padding: 8px 10px; margin-top: 4px; font-size: 15px;
                border: 1px solid #cbd5e1; border-radius: 4px; }
        button { margin-top: 24px; width: 100%; padding: 10px;
                 background: #3b82f6; color: white; border: none;
                 font-size: 15px; border-radius: 4px; cursor: pointer; }
        .error { background: #fef2f2; color: #b91c1c; padding: 10px;
                 border-radius: 4px; font-size: 13px; margin-bottom: 8px; }
      </style>
    </head>
    <body>
    <div class="card">
      <h1>#{title}</h1>
      #{error_html}
      <form method="POST" action="/login">
        <input type="hidden" name="_csrf_token" value="#{csrf}">
        <label>Username
          <input type="text" name="username" autocomplete="username">
        </label>
        <label>Password
          <input type="password" name="password" autocomplete="#{if bootstrap?, do: "new-password", else: "current-password"}">
        </label>
        #{password_confirm_html}
        <button type="submit">#{btn_label}</button>
      </form>
    </div>
    </body>
    </html>
    """
  end

  defp render_users_page(users, current_user, error \\ nil) do
    csrf = Plug.CSRFProtection.get_csrf_token()

    error_html =
      if error,
        do:
          ~s(<div style="color:#b91c1c;background:#fef2f2;padding:10px;border-radius:4px;font-size:13px;margin-bottom:12px">#{Plug.HTML.html_escape(error)}</div>),
        else: ""

    user_rows =
      Enum.map_join(users, "\n", fn user ->
        uname = Plug.HTML.html_escape(user.username)
        role = user.role

        """
        <div class="source-row">
          <div class="source-header">
            <div>
              <span class="source-type">#{uname}</span>
              <span class="source-desc">#{Plug.HTML.html_escape(role)}</span>
            </div>
            <div class="source-actions">
              <button class="btn-secondary" type="button"
                onclick="changeRole('#{uname}', '#{if role == "admin", do: "editor", else: "admin"}')">
                Make #{if role == "admin", do: "Editor", else: "Admin"}
              </button>
              <button class="btn-danger" type="button"
                onclick="deleteUser('#{uname}')">Delete</button>
            </div>
          </div>
        </div>
        """
      end)

    empty_msg =
      if users == [],
        do: ~s(<p style="color:#94a3b8;font-size:14px">No users yet.</p>),
        else: ""

    """
    <!DOCTYPE html>
    <html>
    <head>
      <title>NervesPhotos Settings</title>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="csrf-token" content="#{csrf}">
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: sans-serif; background: #f8f9fa; min-height: 100vh; }
        .page { display: flex; min-height: 100vh; }
        .sidebar { width: 200px; background: #1e293b; flex-shrink: 0; padding-top: 24px; display: flex; flex-direction: column; }
        .sidebar-title { color: #64748b; font-size: 11px; letter-spacing: 1px; text-transform: uppercase; padding: 0 20px 12px; }
        .nav-item { display: block; padding: 10px 20px; color: #94a3b8; cursor: pointer; font-size: 14px; border-left: 3px solid transparent; text-decoration: none; }
        .nav-item.active { color: #e2e8f0; background: #334155; border-left-color: #3b82f6; }
        .content { flex: 1; padding: 32px; max-width: 520px; }
        .section-title { font-size: 18px; font-weight: 600; color: #1e293b; margin-bottom: 24px; }
        label { display: block; margin-top: 16px; font-size: 13px; color: #64748b; text-transform: uppercase; letter-spacing: 0.5px; }
        input[type=text], input[type=number], input[type=password], select { width: 100%; padding: 8px 10px; margin-top: 4px; box-sizing: border-box; font-size: 15px; border: 1px solid #cbd5e1; border-radius: 4px; }
        .btn-primary { padding: 9px 20px; background: #3b82f6; color: white; border: none; font-size: 14px; border-radius: 4px; cursor: pointer; }
        .btn-secondary { padding: 7px 14px; background: #e2e8f0; color: #475569; border: none; font-size: 13px; border-radius: 4px; cursor: pointer; }
        .btn-danger { padding: 7px 10px; background: transparent; color: #ef4444; border: 1px solid #fecaca; font-size: 12px; border-radius: 4px; cursor: pointer; }
        .source-row { background: white; border: 1px solid #e2e8f0; border-radius: 6px; margin-bottom: 8px; }
        .source-header { display: flex; justify-content: space-between; align-items: center; padding: 10px 14px; }
        .source-type { font-size: 13px; font-weight: 600; }
        .source-desc { font-size: 12px; color: #94a3b8; margin-left: 8px; }
        .source-actions { display: flex; gap: 8px; }
        .add-form { background: white; border: 1px solid #e2e8f0; border-radius: 6px; padding: 16px; margin-top: 16px; }
      </style>
    </head>
    <body>
    <div class="page">
      #{NervesPhotos.SettingsRouter.render_sidebar("users", current_user, :users_page)}
      <div class="content">
        <div class="section-title">Users</div>
        #{error_html}
        #{empty_msg}
        #{user_rows}
        <div class="add-form">
          <div style="font-size:13px;font-weight:600;margin-bottom:12px">Add User</div>
          <form method="POST" action="/settings/users">
            <input type="hidden" name="_csrf_token" value="#{csrf}">
            <label>Username
              <input type="text" name="username" required>
            </label>
            <label>Password (min 8 characters)
              <input type="password" name="password" required>
            </label>
            <label>Role
              <select name="role">
                <option value="editor">Editor</option>
                <option value="admin">Admin</option>
              </select>
            </label>
            <button type="submit" class="btn-primary" style="margin-top:16px">Add User</button>
          </form>
        </div>
      </div>
    </div>
    <script>
    function getCsrfToken() {
      var meta = document.querySelector('meta[name="csrf-token"]');
      return meta ? meta.getAttribute('content') : '';
    }
    function deleteUser(username) {
      if (!confirm('Delete user ' + username + '?')) return;
      fetch('/settings/users/' + encodeURIComponent(username), {
        method: 'DELETE',
        headers: {'x-csrf-token': getCsrfToken()}
      }).then(function(r) {
        if (r.ok) { location.reload(); }
        else { r.json().then(function(e) { alert(e.error || 'Delete failed'); }); }
      }).catch(function() { alert('Network error. Please try again.'); });
    }
    function changeRole(username, newRole) {
      fetch('/settings/users/' + encodeURIComponent(username) + '/role', {
        method: 'PATCH',
        headers: {'Content-Type': 'application/json', 'x-csrf-token': getCsrfToken()},
        body: JSON.stringify({role: newRole})
      }).then(function(r) {
        if (r.ok) { location.reload(); }
        else { r.json().then(function(e) { alert(e.error || 'Role change failed'); }); }
      }).catch(function() { alert('Network error. Please try again.'); });
    }
    </script>
    </body>
    </html>
    """
  end
end
