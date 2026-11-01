defmodule JournalAsh.EncryptionTest do
  use ExUnit.Case, async: true
  alias JournalAsh.Encryption

  @key :binary.copy(<<17>>, 32)
  @gcm {Cloak.Ciphers.AES.GCM, tag: "GCM.V1", key: @key}

  test "accepts GCM rotation keys and rejects CTR defaults and fallback keys" do
    config = [ciphers: [default: @gcm, old: {Cloak.Ciphers.AES.GCM, tag: "GCM.V0", key: @key}]]
    assert Encryption.validate_config!(config) == config

    for cipher <- [Cloak.Ciphers.AES.CTR, Cloak.Ciphers.Deprecated.AES.CTR] do
      ctr = {cipher, tag: "CTR.V0", key: @key}

      for ciphers <- [[default: ctr], [default: @gcm, old: ctr]] do
        assert_raise ArgumentError, ~r/only AES-256-GCM/, fn ->
          Encryption.validate_config!(ciphers: ciphers)
        end
      end
    end
  end

  test "rejects missing keys, ambiguous tags and unsafe IV settings" do
    for ciphers <- [
          [],
          [default: {Cloak.Ciphers.AES.GCM, key: <<1>>, tag: "GCM"}],
          [default: @gcm, old: @gcm],
          [default: {Cloak.Ciphers.AES.GCM, key: @key, tag: "GCM", iv_length: 1}]
        ] do
      assert_raise ArgumentError, fn -> Encryption.validate_config!(ciphers: ciphers) end
    end
  end
end
