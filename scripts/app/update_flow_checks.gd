extends RefCounted

const UpdateIdentity := preload("res://scripts/runtime/update_identity.gd")
const UpdateApplier := preload("res://scripts/runtime/update_applier.gd")

const IDENTITY_PATH := "user://update-flow-identity.json"
const ARTIFACT_PATH := "user://update-flow-artifact.bin"
const INSTALL_PATH := "user://update-flow-install.bin"
const COMMIT_A := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const COMMIT_B := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const DIGEST_C := "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
const FRIEND := {
	"channel": "friends-1", "build_id": "friends-old", "commit_sha": COMMIT_A,
	"published_at": "2026-08-01T00:00:00Z", "endpoint": "https://relay.test",
	"invite_token": "friend-token", "tester_id": "PKMN-EEVEE-TEST",
}
const SHARED := {
	"schema_version": 1, "channel": "playtest", "published_at": "2026-08-19T18:00:00Z",
	"build_id": "playtest-newbuild", "commit_sha": COMMIT_B, "min_save_version": 6,
	"builds": {
		"linux": {"url": "https://cdn.test/linux", "sha256": DIGEST_C, "bytes": 4,
			"filename": "PokeWilds-linux.x86_64"},
		"windows": {"url": "https://cdn.test/windows", "sha256": DIGEST_C, "bytes": 4,
			"filename": "PokeWilds-windows.exe"},
		"macos": {"url": "https://cdn.test/macos", "sha256": DIGEST_C, "bytes": 4,
			"filename": "PokeWilds-macos.zip"},
	},
}


static func friend_build() -> Dictionary:
	return FRIEND.duplicate(true)


static func shared_latest() -> Dictionary:
	return SHARED.duplicate(true)


static func reset_user_state() -> void:
	for path in [IDENTITY_PATH, ARTIFACT_PATH, INSTALL_PATH, INSTALL_PATH + ".new",
			INSTALL_PATH + ".old", "user://PokeWilds-update.cmd", "user://updates/applied.json",
			"user://updates/pending.json"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	UpdateApplier.set_helper_starter_for_smoke(Callable())
	UpdateApplier.set_chmod_runner_for_smoke(Callable())
	UpdateIdentity.set_write_fail_for_smoke(false)


static func expect_skip(failures: Array, updater: Node) -> void:
	_check(failures, updater != null and not updater.should_check(), "editor/scenario boot did not skip the network check")


static func expect_default_rows(failures: Array, title: Node, has_save: bool) -> void:
	var expected: Array = ["CONTINUE", "NEW GAME"] if has_save else ["NEW GAME"]
	_check(failures, title.entry_labels() == expected, "default title rows %s != %s" % [str(title.entry_labels()), str(expected)])


static func expect_update_row(failures: Array, title: Node, has_save: bool) -> void:
	var expected: Array = ["UPDATE", "CONTINUE", "NEW GAME"] if has_save else ["UPDATE", "NEW GAME"]
	_check(failures, title.entry_labels() == expected, "UPDATE row %s != %s" % [str(title.entry_labels()), str(expected)])


static func expect_selection_kept(failures: Array, title: Node, label: String) -> void:
	_check(failures, title.entry_row_text(title.selected_entry()) == label,
		"async UPDATE stole the title cursor from %s" % label)


static func expect_identity_persist_refuse(failures: Array, updater: Node) -> void:
	UpdateIdentity.set_path_for_smoke(IDENTITY_PATH)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(IDENTITY_PATH))
	UpdateIdentity.set_write_fail_for_smoke(true)
	if updater != null and updater.has_method("smoke_set_build_info"):
		updater.smoke_set_build_info(friend_build())
	_check(failures, updater != null and not updater.persist_identity(),
		"identity persist failure was ignored")
	_check(failures, UpdateIdentity.load_identity().is_empty(),
		"failed persist still wrote playtest identity")
	UpdateIdentity.set_write_fail_for_smoke(false)
	if updater != null and updater.has_method("smoke_set_build_info"):
		updater.smoke_set_build_info({})


static func persist_friend(failures: Array) -> void:
	UpdateIdentity.set_path_for_smoke(IDENTITY_PATH)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(IDENTITY_PATH))
	_check(failures, UpdateIdentity.persist_from(FRIEND), "friend identity did not persist")
	var merged := UpdateIdentity.merge({"channel": "playtest", "build_id": "playtest-newbuild",
		"commit_sha": COMMIT_B, "endpoint": "https://other.test", "invite_token": "cohort",
		"tester_id": "UNASSIGNED"}, UpdateIdentity.load_identity())
	_check(failures, str(merged.get("invite_token", "")) == "friend-token", "persisted friend token did not win")
	_check(failures, str(merged.get("tester_id", "")) == "PKMN-EEVEE-TEST", "persisted tester_id did not win")
	_check(failures, str(merged.get("build_id", "")) == "playtest-newbuild", "embedded build_id was not kept")
	_check(failures, str(merged.get("channel", "")) == "friends-1", "persisted friend channel did not stay on F reports")


static func expect_shared_channel(failures: Array, updater: Node) -> void:
	_check(failures, updater != null and updater.update_channel() == "playtest",
		"update check used the friend feedback channel instead of playtest")


static func expect_embedded_update_endpoint(failures: Array, updater: Node) -> void:
	var stored := UpdateIdentity.load_identity()
	_check(failures, str(stored.get("endpoint", "")) == "https://relay.test",
		"friend endpoint was not persisted for F reports")
	_check(failures, updater != null and updater.update_endpoint() != str(stored.get("endpoint", "")),
		"update check used the persisted friend endpoint")


static func expect_os_gate(failures: Array, updater: Node) -> void:
	var latest := shared_latest()
	_check(failures, updater != null and updater.is_offerable_build(latest, {}, {}, "Linux"),
		"Linux was not offered a newer shared latest")
	_check(failures, updater.is_offerable_build(latest, {}, {}, "Windows"),
		"Windows was not offered a newer shared latest")
	_check(failures, updater.is_offerable_build(latest, {}, {}, "macOS"),
		"macOS was not offered a newer shared latest")
	_check(failures, not updater.is_offerable_build(latest, {}, {}, "Android"),
		"unknown OS was offered UPDATE")
	_check(failures, not updater.is_offerable_build(latest, {}, {}, ""),
		"empty OS was offered UPDATE")


static func hash_mismatch_payload() -> PackedByteArray:
	return PackedByteArray([1, 2, 3, 4])


static func write_install_fixture() -> void:
	var file := FileAccess.open(INSTALL_PATH, FileAccess.WRITE)
	file.store_buffer(PackedByteArray([9, 9, 9, 9]))
	file.close()
	file = FileAccess.open(ARTIFACT_PATH, FileAccess.WRITE)
	file.store_buffer(PackedByteArray([1, 2, 3, 4]))
	file.close()


static func expect_no_downgrade(failures: Array, updater: Node) -> void:
	var latest := shared_latest()
	_check(failures, updater != null and not updater.is_newer_build(latest, {"build_id": "friends-old"}),
		"unstamped friend build was treated as older than the shared latest")
	_check(failures, updater.is_newer_build(latest, {"build_id": "friends-1-aaaaaaaaaa-20260801T000000Z"}),
		"stamped older friend build_id did not count as older")
	_check(failures, not updater.is_newer_build(latest, {"build_id": "friends-1-aaaaaaaaaa-20260820T000000Z"}),
		"stamped newer friend build_id was offered as a downgrade")


static func apply_linux_fixture(failures: Array) -> void:
	write_install_fixture()
	UpdateApplier.set_chmod_runner_for_smoke(func(_path: String) -> bool: return false)
	var refused := UpdateApplier.apply("Linux", ARTIFACT_PATH, INSTALL_PATH)
	_check(failures, not bool(refused.get("ok", false)), "linux apply ignored a chmod failure")
	_check(failures, FileAccess.get_file_as_bytes(INSTALL_PATH) == PackedByteArray([9, 9, 9, 9]),
		"linux apply promoted after chmod failed")
	_check(failures, not FileAccess.file_exists(INSTALL_PATH + ".old"),
		"linux chmod refuse moved the live binary to .old")
	UpdateApplier.set_chmod_runner_for_smoke(Callable())
	write_install_fixture()
	var result := UpdateApplier.apply("Linux", ARTIFACT_PATH, INSTALL_PATH)
	_check(failures, bool(result.get("ok", false)), "linux apply refused a user:// artifact path")
	_check(failures, FileAccess.get_file_as_bytes(INSTALL_PATH) == PackedByteArray([1, 2, 3, 4]),
		"linux apply did not replace the install bytes")
	_check(failures, not FileAccess.file_exists(INSTALL_PATH + ".new"),
		"linux apply left a sibling staging file")
	_check(failures, not FileAccess.file_exists(INSTALL_PATH + ".old"),
		"linux apply left the previous binary at .old")


static func apply_windows_fixture(failures: Array) -> void:
	write_install_fixture()
	var result := UpdateApplier.apply("Windows", ARTIFACT_PATH, INSTALL_PATH)
	_check(failures, bool(result.get("ok", false)) and bool(result.get("deferred", false)),
		"windows apply did not stage a deferred helper swap")
	_check(failures, FileAccess.get_file_as_bytes(INSTALL_PATH) == PackedByteArray([9, 9, 9, 9]),
		"windows apply mutated the running image in-process")
	_check(failures, FileAccess.get_file_as_bytes(INSTALL_PATH + ".new") == PackedByteArray([1, 2, 3, 4]),
		"windows apply did not stage the new bytes beside the exe")
	_check(failures, FileAccess.file_exists(str(result.get("helper", ""))),
		"windows apply did not write PokeWilds-update.cmd")
	var helper_text: String = FileAccess.get_file_as_string(str(result.get("helper", "")))
	_check(failures, helper_text.contains("if errorlevel 1"),
		"windows helper does not roll back a failed promote")
	UpdateApplier.set_helper_starter_for_smoke(func(_helper: String) -> int: return -1)
	_check(failures, not UpdateApplier.launch_deferred(result),
		"windows helper launch failure was treated as success")
	UpdateApplier.set_helper_starter_for_smoke(func(_helper: String) -> int: return 1)
	_check(failures, UpdateApplier.launch_deferred(result),
		"windows helper launch success was refused")
	UpdateApplier.set_helper_starter_for_smoke(Callable())


static func expect_download_cleared(failures: Array) -> void:
	_check(failures, not FileAccess.file_exists("user://updates/PokeWilds-linux.x86_64"),
		"refused update left a downloaded artifact")
	_check(failures, not FileAccess.file_exists("user://updates/pending.json"),
		"refused update left pending.json")


static func expect_staging_cleared(failures: Array) -> void:
	_check(failures, not FileAccess.file_exists("user://updates/pending.json"),
		"successful apply left pending.json")
	_check(failures, not FileAccess.file_exists("user://updates/PokeWilds-linux.x86_64"),
		"successful apply left the downloaded artifact")
	_check(failures, FileAccess.file_exists("user://updates/applied.json"),
		"successful apply did not keep applied.json")


static func _check(failures: Array, ok: bool, reason: String) -> void:
	if not ok:
		failures.append(reason)
