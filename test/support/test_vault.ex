defmodule JournalAsh.TestVault do
  @moduledoc false

  use Cloak.Vault, otp_app: :journal_ash
end

defmodule JournalAsh.TestWrongVault do
  @moduledoc false

  use Cloak.Vault, otp_app: :journal_ash
end

defmodule JournalAsh.TestInvalidVault do
  @moduledoc false

  def encrypt(_plaintext), do: :invalid_return
  def decrypt(_ciphertext), do: :invalid_return
end

defmodule JournalAsh.TestRaisingVault do
  @moduledoc false

  def encrypt(_plaintext), do: raise("synthetic vault failure with private detail")
  def decrypt(_ciphertext), do: raise("synthetic vault failure with private detail")
end
