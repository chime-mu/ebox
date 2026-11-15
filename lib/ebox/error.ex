defmodule Ebox.Error do
  @moduledoc """
  Error returned by every `Ebox` call.

  `step` names the operation that failed, `status` is the HTTP status when the
  server answered, `code` is the service's own error code when it sent one, and `body`
  is the raw response body (useful when e-Boks changes something and the
  client needs adjusting).
  """
  defexception [:step, :status, :code, :message, :body]

  @type t :: %__MODULE__{
          step: atom(),
          status: pos_integer() | nil,
          code: String.t() | nil,
          message: String.t(),
          body: term()
        }

  @doc false
  def new(step, message, fields \\ []) do
    struct!(__MODULE__, [step: step, message: message] ++ fields)
  end

  @doc false
  def from_response(step, %Req.Response{} = resp) do
    {code, detail} = describe(resp.body)

    new(step, "#{step} failed with HTTP #{resp.status}#{detail}",
      status: resp.status,
      code: code,
      body: resp.body
    )
  end

  @doc false
  def from_exception(step, exception) do
    new(step, "#{step} failed: #{Exception.message(exception)}")
  end

  defp describe(%{"description" => %{"text" => text}}) when is_binary(text),
    do: {nil, ": " <> text}

  defp describe(%{"error_description" => text}) when is_binary(text), do: {nil, ": " <> text}
  defp describe(%{"error" => text}) when is_binary(text), do: {nil, ": " <> text}
  defp describe(body) when is_binary(body), do: {nil, text_detail(body)}
  defp describe(_), do: {nil, ""}

  defp text_detail(body) do
    if body != "" and String.valid?(body),
      do: ": " <> String.slice(String.trim(body), 0, 300),
      else: ""
  end
end
