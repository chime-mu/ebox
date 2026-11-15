defmodule Ebox do
  @moduledoc """
  Your Danish digital mail, from both systems, without MitID after a one-time
  activation:

    * `Ebox.Eboks` – e-Boks ("Post fra virksomheder": banks, utilities,
      employers…), your own mailbox and mailboxes shared with you, through the
      JSON API of the e-Boks mobile app.
    * `Ebox.DigitalPost` – Digital Post ("Post fra det offentlige": Skat,
      municipalities…), your own mailbox and those of companies you represent,
      through the state's official API for view clients.
    * `Ebox.Archive` – a local copy of all of it, laid out like the e-Boks app.
    * `Ebox.Auth` – the one-time activation with MitID (`mix ebox.auth`).

  Both clients run on one stored login; see `docs/how-it-connects.md`.

      {:ok, dp} = Ebox.DigitalPost.connect()
      {:ok, eb} = Ebox.Eboks.connect(digitalpost: dp)
      Ebox.Eboks.mailboxes(eb)
      Ebox.DigitalPost.mailboxes(dp)
  """
end
