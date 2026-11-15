defmodule Ebox.Error do
  @moduledoc """
  Error returned by every `Ebox` call.

  `step` names the operation that failed, `status` is the HTTP status when the
  server answered, `code` is e-Boks' own error code when it sent one, and `body`
  is the raw response body (useful when e-Boks changes something and the
  connector needs adjusting).
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

  # The mobile XML API answers errors with <Error><ErrorCode/><ErrorText/></Error>.
  defp describe("<Error" <> _ = body) do
    with {:ok, doc} <- Ebox.XML.parse(body),
         [%{text: text} | _] <- Ebox.XML.children(doc, "ErrorText") do
      code =
        with [%{text: code} | _] <- Ebox.XML.children(doc, "ErrorCode"),
             do: code,
             else: (_ -> nil)

      {code, ": #{text}" <> if(code, do: " (e-Boks error #{code})", else: "")}
    else
      _ -> {nil, text_detail(body)}
    end
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
