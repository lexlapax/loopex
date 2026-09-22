defmodule LoopexDaemon.SuccessionCapacityTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.SuccessionCapacity
  alias LoopexProtocol.Session.V2

  test "the reserve is derived from every maximal legal succession record" do
    measurement = SuccessionCapacity.measure()

    assert length(measurement.reply_candidates) == 37
    assert Enum.uniq_by(measurement.reply_candidates, & &1.id) == measurement.reply_candidates

    assert measurement.reply_bytes ==
             measurement.reply_candidates |> Enum.map(& &1.bytes) |> Enum.max()

    assert measurement.delivery_reserve_bytes ==
             measurement.notice_bytes + measurement.reply_bytes

    assert measurement.delivery_reserve_bytes < Map.fetch!(V2.limits(), "durable_queue_bytes")

    assert measurement.delivery_reserve_bytes *
             Map.fetch!(V2.limits(), "connections_per_daemon") <= 536_870_912
  end

  test "literal lengths and digests pin the notice and every reply candidate" do
    measurement = SuccessionCapacity.measure()

    assert measurement.notice_bytes == 496

    assert measurement.notice_sha256 ==
             "881813d1bd081c759e4352f846c8917f149b8e10434df66ef98259e3c79aa9e6"

    assert measurement.reply_bytes == 87_595

    assert measurement.reply_id ==
             "session.respond_interaction/refused/invalid_interaction_answer"

    assert measurement.delivery_reserve_bytes == 88_091

    assert Enum.map(measurement.reply_candidates, &{&1.id, &1.bytes, &1.sha256}) == [
             {"session.resume/accepted", 877,
              "d41ec746e328a37d0fafabfa6995cfd4a9842a01d25dcad4aa266c571e0b39d5"},
             {"session.resume/refused/runtime_command_conflict", 540,
              "5d49e3b2fd389d8caf9e75ee0eaaae691bf67ff51bb21c1a7175c09faf2f3370"},
             {"session.prompt/accepted", 87_559,
              "f589d1f351517237e21dadc1ad891257e7e4e19ccdd9e49edd508c0f2eba0f5e"},
             {"session.prompt/refused/run_active", 87_566,
              "96c246f5577a11b39673ceef474827bcbde8964bc92b50190a67990da6df96ec"},
             {"session.steer/accepted", 87_558,
              "741edf068f20f7c018bde9431bfa1cca6d1f2200fd04fc0a6fd70b281d4814dc"},
             {"session.steer/refused/run_mismatch", 87_567,
              "7cb9248feafd699632da259218ffd3460f2c5d873b735a36b20c1035357673e8"},
             {"session.steer/refused/steer_pending", 87_568,
              "91d61b09fdd6048d24564ff8c30728187cce157221213f956543b29a834f0d1a"},
             {"session.steer/refused/no_active_run", 87_568,
              "3eac1e3a61fe009b93687546765078ea08e56d474b3054c621e21633119731d9"},
             {"session.follow_up/accepted", 87_562,
              "bd583a0b6ae8fdeff3efb30c6faeaac77f4b44aa4b29854c66eadada08c51a6f"},
             {"session.follow_up/refused/follow_up_pending", 87_576,
              "0938be4836fe2f3151ceecfeb1222cf881c158ad904144cf080154b960ac1956"},
             {"session.follow_up/refused/no_active_run", 87_572,
              "f8a572284e38ac783305a65476950e4a8f0807ab7f6d12e9c777c84473a5244c"},
             {"session.abort/accepted", 87_558,
              "949aa2e8e7846d96d5dfff6b4239a24fdbc3fda436e5823fea32ed89764f6d9e"},
             {"session.abort/refused/no_active_run", 87_568,
              "bfce90b156089ed04e0aecc1328dca22c3841a194c9bc52ddebdcf9e56260da9"},
             {"session.respond_interaction/accepted", 87_572,
              "d31297b7470716d659dc7f7432cc428cac91c1f77d7c7bf714ce2a134671b27a"},
             {"session.respond_interaction/refused/interaction_absent", 87_587,
              "2e59ca7f752a960b38070599bfb2b217ef18b4cf168b893795a4781e87e1495f"},
             {"session.respond_interaction/refused/interaction_resolved", 87_589,
              "3b3ab067e8c22e6ddd3124b7a8b4c3afe2bfbeb7a22ea424f37ff83c1501e91a"},
             {"session.respond_interaction/refused/invalid_interaction_answer", 87_595,
              "19fdb2bd354a8c155fe408d4adad53c2e2b28a5b65ee5d60e16779bba4662476"},
             {"session.admit_resources/accepted", 528,
              "ed0303b4c61e5fb8112fc3be249b617ef2bef130d231d913694b9f284d8e7263"},
             {"session.admit_resources/refused/run_active", 535,
              "4317293ef25d2c7199162bafd36160ca3265bdefc1572839053a5282e00e5bc3"},
             {"session.admit_resources/refused/resource_manifest_missing", 550,
              "a3159d7c659b9c3e83613ae6123e4e5db4b55b0c047dfc348f37a277a85ee274"},
             {"session.admit_resources/refused/resource_binding_changed", 549,
              "8fd9dcee67197ec966e30d8eaf2da8bf5eff5fa3adee7901f00c53439e643f1e"},
             {"session.admit_resources/refused/resource_not_admitted", 546,
              "6a048894880ba22c29da338a4869b85fdf0546d2279c5528b14a1afc20db3ec1"},
             {"session.admit_resources/refused/resource_not_found", 543,
              "d0f71bcab93f495babf3b3ec2fad394a9910f0b13f88539004027f9ee3b310ab"},
             {"session.admit_resources/refused/resource_selection_limit", 549,
              "66acca386303e5293b62efcb4410d66dac96bd4c015f69306f96095916dce4af"},
             {"session.admit_resources/refused/resource_support_not_found", 551,
              "5a478fdb354a086ce22e7fc1719447ff7750239034598bc41a7326e7e08e06ec"},
             {"session.activate_skill/accepted", 527,
              "57a64e39f980fc3c9c7c4acabfbe828fb9b749c0528c0502dd46f9072c6ce227"},
             {"session.activate_skill/refused/run_active", 534,
              "36c5b576cc01e84b5c864962adf1307aab448f454ee685fd8139eb3ac8b5bf9b"},
             {"session.activate_skill/refused/resource_manifest_missing", 549,
              "e5f5731e33d53393c62d5db775ebafe444eb150c173e4c169cc77a7f747d55c9"},
             {"session.activate_skill/refused/resource_binding_changed", 548,
              "c4fca1400c805bbc767dee11d5037d74cd84c24273b69634ef9942193b37d6b2"},
             {"session.activate_skill/refused/resource_not_admitted", 545,
              "8353a57bc6b04bb7edb5a928cf6f4eccc13b3cf86ca4a731fffe6ef3d0bfcb0b"},
             {"session.activate_skill/refused/resource_not_found", 542,
              "ea4d6a5bc5ec71425d342ed69407135b30638c2cf9aa2b37943784418a9d1b5c"},
             {"session.activate_skill/refused/resource_selection_limit", 548,
              "bcb615ef2f86ab5eb05a690967ff00300a9fe81cf3c273ff2b7d7fb938a6b4a0"},
             {"session.activate_skill/refused/resource_support_not_found", 550,
              "e1ea25f1c1419b2ccd3c4fd36c21bc675c90ce5a2903039a97bab10083567540"},
             {"error/admission_unknown", 195,
              "e7474b7429989b15d651262da039b70b91312c42417f07538c9882146f3d59ed"},
             {"error/session_unavailable", 159,
              "072a2a40cc8e0dd48c4054785ffcb2f6a6210763e706e159874371170c8d4c57"},
             {"error/control_not_held", 174,
              "cd68e89667ca2affdea69350e9684085c8cf9452a41afc0a07f0c376b4ac0e5c"},
             {"error/attachment_conflict", 176,
              "33f443b0e4e977cc6fa6c7e1ed00401b4786233fe496636f8dbb211cbcfc9aa7"}
           ]
  end
end
