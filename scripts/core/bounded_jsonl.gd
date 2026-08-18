extends RefCounted

# Complete-record boundary helpers shared by trace capture and feedback bundle
# reduction. Callers choose their byte budgets; this primitive owns the rule
# that no returned prefix or tail starts or ends with a partial JSONL record.


static func complete_prefix(bytes: PackedByteArray) -> PackedByteArray:
	var last_newline := -1
	for index in bytes.size():
		if bytes[index] == 10:
			last_newline = index
	return bytes.slice(0, last_newline + 1) if last_newline >= 0 else PackedByteArray()


static func complete_tail(bytes: PackedByteArray) -> PackedByteArray:
	var start := 0
	while start < bytes.size() and bytes[start] != 10:
		start += 1
	if start < bytes.size():
		start += 1
	return complete_prefix(bytes.slice(start))


static func join(prefix: PackedByteArray, marker: PackedByteArray,
		tail: PackedByteArray) -> PackedByteArray:
	var result := complete_prefix(prefix)
	result.append_array(marker)
	result.append_array(complete_tail(tail))
	return result
