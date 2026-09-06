const std = @import("std");
const builtin = @import("builtin");
const graph = @import("release_adapter_candidate_resume_asset_graph");
const resume_product = @import("release_adapter_candidate_resume_authority_product");
const attachment = @import("release_adapter_github_draft_asset_attachment");
const redownload = @import("release_adapter_github_draft_asset_redownload");
const publication = @import("release_adapter_github_draft_publication");
const post_publish = @import("release_adapter_github_post_publish_attestation");
const cli_mod = @import("release_adapter_github_cli_authority");

const context = resume_product.PublicationContext{
    .repository = .{ .id = 7, .owner = "ohah", .name = "maru" },
    .tag = "v1.2.3",
    .source_commit = "0123456789abcdef0123456789abcdef01234567",
    .build = .{
        .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/heads/main",
        .run_id = 81,
        .run_attempt = 2,
    },
    .protected_tag = true,
};

const FakeSource = struct {
    view: resume_product.PublicationView,
    calls: usize = 0,
    fail_at: ?usize = null,

    pub fn publicationView(
        self: *@This(),
        _: std.mem.Allocator,
        expected: resume_product.PublicationContext,
        cli_path: [:0]const u8,
        cli: *const cli_mod.PinnedExecutable,
    ) !resume_product.PublicationView {
        self.calls += 1;
        if (self.fail_at == self.calls) return error.Injected;
        if (!sameContext(expected, context) or !std.mem.eql(u8, cli_path, "/usr/local/bin/gh") or
            !std.mem.eql(u8, &cli.sha256, &self.view.cli_sha256)) return error.AuthorityChanged;
        return self.view;
    }
};

fn observation(inode: u64, size: u64, byte: u8) resume_product.PublicationObservation {
    return .{
        .identity = .{ .device = 3, .inode = inode },
        .size = size,
        .mode = 0o600,
        .sha256 = @splat(byte),
    };
}

fn sourceView() resume_product.PublicationView {
    return .{
        .context = context,
        .release_id = 91,
        .tag = context.tag,
        .source_commit = context.source_commit,
        .cli_sha256 = @splat('a'),
        .assets = .{
            .{ .path = "/tmp/candidate.dmg", .observation = observation(11, 101, 'b'), .fd = 31 },
            .{ .path = "/tmp/maru-session-host", .observation = observation(12, 102, 'c'), .fd = 32 },
            .{ .path = "/tmp/aggregate/baseline-evidence.json", .observation = observation(13, 103, 'd'), .fd = 33 },
            .{ .path = "/tmp/preparation/Maru-1.2.3-session-host-release.json", .observation = observation(14, 104, 'e'), .fd = 34 },
        },
    };
}

fn pinnedCli() cli_mod.PinnedExecutable {
    return .{
        .path_sha256 = @splat('f'),
        .path_len = 17,
        .identity = .{ .device = 5, .inode = 50 },
        .size = 500,
        .mode = 0o755,
        .sha256 = @splat('a'),
    };
}

fn sameContext(left: resume_product.PublicationContext, right: resume_product.PublicationContext) bool {
    return left.repository.id == right.repository.id and std.mem.eql(u8, left.repository.owner, right.repository.owner) and
        std.mem.eql(u8, left.repository.name, right.repository.name) and std.mem.eql(u8, left.tag, right.tag) and
        std.mem.eql(u8, left.source_commit, right.source_commit) and std.mem.eql(u8, left.build.workflow_ref, right.build.workflow_ref) and
        left.build.run_id == right.build.run_id and left.build.run_attempt == right.build.run_attempt and
        left.protected_tag == right.protected_tag;
}

fn bind(source: *FakeSource, cli: *const cli_mod.PinnedExecutable, authority: *graph.Authority) !void {
    try graph.testing_api.bindWith(source, std.testing.allocator, context, "/usr/local/bin/gh", cli, authority);
}

fn attachedFrom(snapshot: attachment.Snapshot) attachment.DraftAssets {
    var result = attachment.DraftAssets{
        .status = .ready,
        .release_id = snapshot.release_id,
        .known_count = attachment.asset_count,
    };
    result.owner = &result;
    for (snapshot.assets, 0..) |asset, index| {
        result.ids[index] = 201 + index;
        result.sizes[index] = asset.size;
        result.name_lens[index] = asset.name.len;
        @memcpy(result.names[index][0..asset.name.len], asset.name);
        result.views[index] = .{ .id = result.ids[index], .name = result.names[index][0..asset.name.len], .size = asset.size };
    }
    return result;
}

fn rebindAttached(result: *attachment.DraftAssets) void {
    result.owner = result;
    for (&result.views, 0..) |*view, index| view.* = .{
        .id = result.ids[index],
        .name = result.names[index][0..result.name_lens[index]],
        .size = result.sizes[index],
    };
}

fn validatedFrom(attached: *const attachment.DraftAssets) redownload.RedownloadValidation {
    var result = redownload.RedownloadValidation{
        .status = .ready,
        .release_id = attached.release_id,
        .asset_ids = attached.ids,
    };
    result.owner = &result;
    return result;
}

fn publishedFrom(source: resume_product.PublicationView, attached: *const attachment.DraftAssets) publication.PublishedRelease {
    var result = publication.PublishedRelease{
        .status = .ready,
        .release_id = source.release_id,
        .tag_len = source.tag.len,
        .asset_ids = attached.ids,
    };
    result.owner = &result;
    @memcpy(result.tag[0..source.tag.len], source.tag);
    @memcpy(&result.source_commit, source.source_commit);
    return result;
}

test "ready resume authority projects the four publication snapshots in exact order" {
    var source = FakeSource{ .view = sourceView() };
    var cli = pinnedCli();
    var authority = graph.Authority{};
    try bind(&source, &cli, &authority);
    defer authority.deinit() catch unreachable;

    const initial = try authority.snapshotAttachment();
    try std.testing.expectEqual(@as(u64, 91), initial.release_id);
    try std.testing.expectEqual(@as(usize, 4), initial.assets.len);
    try std.testing.expectEqualStrings("candidate.dmg", initial.assets[0].name);
    try std.testing.expectEqualStrings("maru-session-host", initial.assets[1].name);
    try std.testing.expectEqualStrings("baseline-evidence.json", initial.assets[2].name);
    try std.testing.expectEqualStrings("Maru-1.2.3-session-host-release.json", initial.assets[3].name);
    try std.testing.expectEqual(@as(std.c.fd_t, 34), initial.assets[3].fd);

    var attached = attachedFrom(initial);
    rebindAttached(&attached);
    const downloaded = try authority.snapshotRedownload(&attached);
    for (downloaded.assets, 0..) |asset, index| try std.testing.expectEqual(attached.ids[index], asset.id);

    var validated = validatedFrom(&attached);
    validated.owner = &validated;
    const published_snapshot = try authority.snapshotPublication(&attached, &validated);
    try std.testing.expectEqualStrings(context.tag, published_snapshot.tag);
    try std.testing.expectEqualStrings(context.source_commit, published_snapshot.source_commit);

    var published = publishedFrom(source.view, &attached);
    published.owner = &published;
    const verified = try authority.snapshotPostPublish(&attached, &validated, &published);
    for (verified.artifacts, 0..) |artifact, index| {
        try std.testing.expectEqual(attached.ids[index], artifact.id);
        try std.testing.expectEqualStrings(source.view.assets[index].path, artifact.path);
    }
    try std.testing.expectEqual(@as(usize, 5), source.calls);
}

test "every projection re-fences the exact source and fails before publishing drift" {
    var source = FakeSource{ .view = sourceView(), .fail_at = 3 };
    var cli = pinnedCli();
    var authority = graph.Authority{};
    try bind(&source, &cli, &authority);
    _ = try authority.snapshotAttachment();
    try std.testing.expectError(error.Injected, authority.snapshotAttachment());
    try std.testing.expectEqual(@as(usize, 3), source.calls);
    try authority.deinit();
}

test "copied moved pre-owned and replaced source or CLI authority fail closed" {
    var source = FakeSource{ .view = sourceView() };
    var cli = pinnedCli();
    var authority = graph.Authority{};
    try bind(&source, &cli, &authority);
    var copied = authority;
    try std.testing.expectError(error.InvalidOwner, copied.snapshotAttachment());

    var other_source = source;
    graph.testing_api.replaceSource(&authority, &other_source);
    try std.testing.expectError(error.InvalidOwner, authority.snapshotAttachment());
    graph.testing_api.replaceSource(&authority, &source);
    var other_cli = cli;
    graph.testing_api.replaceCli(&authority, &other_cli);
    try std.testing.expectError(error.InvalidOwner, authority.snapshotAttachment());
    graph.testing_api.replaceCli(&authority, &cli);
    graph.testing_api.toggleStoredContext(&authority);
    try std.testing.expectError(error.InvalidOwner, authority.snapshotAttachment());
    graph.testing_api.toggleStoredContext(&authority);
    graph.testing_api.toggleStoredCliPath(&authority);
    try std.testing.expectError(error.InvalidOwner, authority.snapshotAttachment());
    graph.testing_api.toggleStoredCliPath(&authority);
    graph.testing_api.setFirstPathLength(&authority, std.fs.max_path_bytes);
    try std.testing.expectError(error.InvalidOwner, authority.snapshotAttachment());
    graph.testing_api.setFirstPathLength(&authority, source.view.assets[0].path.len);
    graph.testing_api.replaceAllocator(&authority, std.heap.page_allocator);
    try std.testing.expectError(error.InvalidOwner, authority.snapshotAttachment());
    graph.testing_api.replaceAllocator(&authority, std.testing.allocator);
    _ = try authority.snapshotAttachment();
    try authority.deinit();

    var preowned = graph.Authority{};
    preowned.owner = &preowned;
    try std.testing.expectError(error.InvalidOwner, bind(&source, &cli, &preowned));
}

test "initial graph rejects every path identity fd and content alias" {
    const Mutation = enum { path, identity, fd, name, empty, relative };
    inline for (std.meta.tags(Mutation)) |mutation| {
        var source = FakeSource{ .view = sourceView() };
        switch (mutation) {
            .path => source.view.assets[1].path = source.view.assets[0].path,
            .identity => source.view.assets[1].observation.identity = source.view.assets[0].observation.identity,
            .fd => source.view.assets[1].fd = source.view.assets[0].fd,
            .name => source.view.assets[1].path = "/other/candidate.dmg",
            .empty => source.view.assets[1].path = "",
            .relative => source.view.assets[1].path = "relative",
        }
        var cli = pinnedCli();
        var authority = graph.Authority{};
        try std.testing.expectError(error.InvalidGraph, bind(&source, &cli, &authority));
    }
}

test "authority storage aliases source and CLI before callback access" {
    var source = FakeSource{ .view = sourceView() };
    var cli = pinnedCli();

    var source_alias = graph.Authority{};
    const aliased_source: *FakeSource = @ptrCast(@alignCast(&source_alias));
    try std.testing.expectError(error.StorageAlias, graph.testing_api.bindWith(
        aliased_source,
        std.testing.allocator,
        context,
        "/usr/local/bin/gh",
        &cli,
        &source_alias,
    ));

    var cli_alias = graph.Authority{};
    const aliased_cli: *const cli_mod.PinnedExecutable = @ptrCast(@alignCast(&cli_alias));
    try std.testing.expectError(error.StorageAlias, graph.testing_api.bindWith(
        &source,
        std.testing.allocator,
        context,
        "/usr/local/bin/gh",
        aliased_cli,
        &cli_alias,
    ));
    try std.testing.expectEqual(@as(usize, 0), source.calls);
}

test "sealed graph rejects every source field drift after bind" {
    const Mutation = enum { release, repository, run, tag, source, workflow, cli, path, device, inode, fd, size, mode, digest };
    inline for (std.meta.tags(Mutation)) |mutation| {
        var source = FakeSource{ .view = sourceView() };
        var cli = pinnedCli();
        var authority = graph.Authority{};
        try bind(&source, &cli, &authority);
        switch (mutation) {
            .release => source.view.release_id += 1,
            .repository => source.view.context.repository.id += 1,
            .run => source.view.context.build.run_attempt += 1,
            .tag => source.view.tag = "v9.9.9",
            .source => source.view.source_commit = "1123456789abcdef0123456789abcdef01234567",
            .workflow => source.view.context.build.workflow_ref = "other",
            .cli => source.view.cli_sha256[0] = 'f',
            .path => source.view.assets[0].path = "/tmp/other.dmg",
            .device => source.view.assets[0].observation.identity.device += 1,
            .inode => source.view.assets[0].observation.identity.inode += 1,
            .fd => source.view.assets[0].fd += 1,
            .size => source.view.assets[0].observation.size += 1,
            .mode => source.view.assets[0].observation.mode ^= 0o100,
            .digest => source.view.assets[0].observation.sha256[0] = 'f',
        }
        try std.testing.expectError(error.AuthorityChanged, authority.snapshotAttachment());
        source.view = sourceView();
        try authority.deinit();
    }
}

test "attachment receipt must bind every remote id name and size" {
    var source = FakeSource{ .view = sourceView() };
    var cli = pinnedCli();
    var authority = graph.Authority{};
    try bind(&source, &cli, &authority);
    defer authority.deinit() catch unreachable;
    const initial = try authority.snapshotAttachment();
    var attached = attachedFrom(initial);
    rebindAttached(&attached);

    attached.release_id += 1;
    try std.testing.expectError(error.ReceiptMismatch, authority.snapshotRedownload(&attached));
    attached.release_id -= 1;
    attached.ids[0] = 0;
    try std.testing.expectError(error.ReceiptMismatch, authority.snapshotRedownload(&attached));
    attached.ids[0] = 201;
    attached.sizes[0] += 1;
    try std.testing.expectError(error.ReceiptMismatch, authority.snapshotRedownload(&attached));
    attached.sizes[0] -= 1;
    attached.names[0][0] = 'x';
    try std.testing.expectError(error.ReceiptMismatch, authority.snapshotRedownload(&attached));
    attached.name_lens[0] = attached.names[0].len + 1;
    try std.testing.expectError(error.ReceiptMismatch, authority.snapshotRedownload(&attached));
}

test "redownload and publication receipts bind exact release and four asset IDs" {
    var source = FakeSource{ .view = sourceView() };
    var cli = pinnedCli();
    var authority = graph.Authority{};
    try bind(&source, &cli, &authority);
    defer authority.deinit() catch unreachable;
    var attached = attachedFrom(try authority.snapshotAttachment());
    rebindAttached(&attached);
    var validated = validatedFrom(&attached);
    validated.owner = &validated;

    validated.asset_ids[2] += 1;
    try std.testing.expectError(error.ReceiptMismatch, authority.snapshotPublication(&attached, &validated));
    validated.asset_ids = attached.ids;
    var published = publishedFrom(source.view, &attached);
    published.owner = &published;
    published.asset_ids[3] += 1;
    try std.testing.expectError(error.ReceiptMismatch, authority.snapshotPostPublish(&attached, &validated, &published));
    published.asset_ids = attached.ids;
    published.tag[0] = 'x';
    try std.testing.expectError(error.ReceiptMismatch, authority.snapshotPostPublish(&attached, &validated, &published));
    published.tag_len = published.tag.len + 1;
    try std.testing.expectError(error.ReceiptMismatch, authority.snapshotPostPublish(&attached, &validated, &published));
}

test "binding copies scalar context and CLI pathname storage" {
    var source = FakeSource{ .view = sourceView() };
    var cli = pinnedCli();
    var cli_path: [64:0]u8 = @splat(0);
    @memcpy(cli_path[0..17], "/usr/local/bin/gh");
    var authority = graph.Authority{};
    try graph.testing_api.bindWith(&source, std.testing.allocator, context, cli_path[0..17 :0], &cli, &authority);
    cli_path[1] = 'x';
    _ = try authority.snapshotAttachment();
    try authority.deinit();
}

test "deinit consumes only the adapter and leaves the resume source reusable" {
    var source = FakeSource{ .view = sourceView() };
    var cli = pinnedCli();
    var authority = graph.Authority{};
    try bind(&source, &cli, &authority);
    try authority.deinit();
    try std.testing.expectError(error.InvalidOwner, authority.snapshotAttachment());

    var rebound = graph.Authority{};
    try bind(&source, &cli, &rebound);
    _ = try rebound.snapshotAttachment();
    try rebound.deinit();
}

test "production source exposes one full publication fence and graph adapter owns no remote work" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_resume_authority_product.zig", std.testing.allocator, .limited(192 * 1024));
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "pub fn publicationView("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "const preparation = try execution.preparation.fence("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "const aggregate = try execution.aggregate.fence()"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, "requireCrossIdentityGraph("));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, source, "requireSemanticGraphImpl("));

    const adapter = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_resume_asset_graph.zig", std.testing.allocator, .limited(128 * 1024));
    defer std.testing.allocator.free(adapter);
    inline for (.{ "GH_TOKEN", "bounded_process", ".upload(", ".download(", ".publish(" }) |forbidden|
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, adapter, forbidden));
}

test "projection overhead records batched latency without FD growth" {
    const sample_count = 40;
    const iterations_per_sample = 1000;
    var samples: [sample_count]u64 = undefined;
    var source = FakeSource{ .view = sourceView() };
    var cli = pinnedCli();
    var authority = graph.Authority{};
    try bind(&source, &cli, &authority);
    defer authority.deinit() catch unreachable;
    const fd_before = try openFdCount();

    for (&samples) |*sample| {
        const started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        for (0..iterations_per_sample) |_| _ = try authority.snapshotAttachment();
        sample.* = @intCast(@divTrunc(std.Io.Clock.awake.now(std.testing.io).nanoseconds - started, iterations_per_sample));
    }

    const fd_after = try openFdCount();
    try std.testing.expectEqual(fd_before, fd_after);
    try std.testing.expectEqual(@as(usize, 1 + sample_count * iterations_per_sample), source.calls);
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    std.debug.print("resume_asset_graph_projection mode={s} samples=40 iterations_per_sample=1000 failures=0 fd_delta=0 per_call_median_ns={d} per_call_p95_ns={d} per_call_max_ns={d}\n", .{
        @tagName(builtin.mode),
        samples[20],
        samples[37],
        samples[39],
    });
}

fn openFdCount() !u32 {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, "/dev/fd", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: u32 = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    return count;
}
