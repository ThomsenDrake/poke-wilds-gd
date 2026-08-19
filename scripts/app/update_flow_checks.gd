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
	for path in [IDENTITY_PATH, ARTIFACT_PATH, INSTALL_PATH,
			"user://updates/applied.json", "user://updates/pending.json"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


static func expect_skip(failures: Array, updater: Node) -> void:
	_check(failures, updater != null and not updater.should_check(), "editor/scenario boot did not skip the network check")


static func expect_default_rows(failures: Array, title: Node, has_save: bool) -> void:
	var expected: Array = ["CONTINUE", "NEW GAME"] if has_save else ["NEW GAME"]
	_check(failures, title.entry_labels() == expected, "default title rows %s != %s" % [str(title.entry_labels()), str(expected)])


static func expect_update_row(failures: Array, title: Node, has_save: bool) -> void:
	var expected: Array = ["UPDATE", "CONTINUE", "NEW GAME"] if has_save else ["UPDATE", "NEW GAME"]
	_check(failures, title.entry_labels() == expected, "UPDATE row %s != %s" % [str(title.entry_labels()), str(expected)])
	_check(failures, title.entry_row_text(title.selected_entry()) == "UPDATE", "cursor did not start on UPDATE")


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


static func hash_mismatch_payload() -> PackedByteArray:
	return PackedByteArray([1, 2, 3, 4])


static func write_install_fixture() -> void:
	var file := FileAccess.open(INSTALL_PATH, FileAccess.WRITE)
	file.store_buffer(PackedByteArray([9, 9, 9, 9]))
	file.close()
	file = FileAccess.open(ARTIFACT_PATH, FileAccess.WRITE)
	file.store_buffer(PackedByteArray([1, 2, 3, 4]))
	file.close()


static func apply_linux_fixture(failures: Array) -> void:
	write_install_fixture()
	var result := UpdateApplier.apply("Linux", ProjectSettings.globalize_path(ARTIFACT_PATH),
		ProjectSettings.globalize_path(INSTALL_PATH))
	_check(failures, bool(result.get("ok", false)), "linux apply refused a valid artifact")
	_check(failures, FileAccess.get_file_as_bytes(INSTALL_PATH) == PackedByteArray([1, 2, 3, 4]),
		"linux apply did not replace the install bytes")


static func _check(failures: Array, ok: bool, reason: String) -> void:
	if not ok:
		failures.append(reason)
