defmodule JournalAsh.Encryption do
  @moduledoc """
  Enforces AES-256-GCM for encrypted journal entries and dependent libraries.

  Every configured key, including rotation keys, must use GCM. CTR and custom
  ciphers are rejected rather than retained as decryption fallbacks.
  """

  def validate_config!(config) do
    ciphers = if Keyword.keyword?(config), do: Keyword.get(config, :ciphers), else: nil

    unless is_list(ciphers) and ciphers != [] and
             Enum.all?(ciphers, &valid_cipher?/1) and unique_tags?(ciphers) do
      raise ArgumentError,
            "vault requires only AES-256-GCM ciphers with distinct tags and 32-byte keys"
    end

    config
  end

  def config(vault) when is_atom(vault) do
    with {:ok, config} <- Cloak.Vault.read_config(:"#{vault}.Config") do
      {:ok, validate_config!(config)}
    else
      _ -> {:error, :invalid_vault}
    end
  rescue
    _ -> {:error, :invalid_vault}
  end

  def config(_), do: {:error, :invalid_vault}

  defp valid_cipher?({label, {Cloak.Ciphers.AES.GCM, opts}}) when is_atom(label) do
    if Keyword.keyword?(opts) do
      key = Keyword.get(opts, :key)
      tag = Keyword.get(opts, :tag)

      is_binary(key) and byte_size(key) == 32 and is_binary(tag) and
        byte_size(tag) in 1..255 and Keyword.get(opts, :iv_length, 16) in [12, 16]
    else
      false
    end
  end

  defp valid_cipher?(_), do: false

  defp unique_tags?(ciphers) do
    tags = Enum.map(ciphers, fn {_, {_, opts}} -> Keyword.fetch!(opts, :tag) end)
    length(tags) == length(Enum.uniq(tags))
  end
end
