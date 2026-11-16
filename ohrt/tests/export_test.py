#!/usr/bin/env python3
"""Checks ohrt/tools/export.py against a small made-up export.

  export_test.py

The export has no documented layout, so the files below are written in the
shapes a real one had in November 2026, with invented accounts. Each shape
that export.py reads is here once, along with the things that tripped it on
the real one: the hashtags file beside following.json, an owner nested two
levels down under a title, and names written out byte by byte.
"""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
import export  # noqa: E402


def put(root, path, data):
    full = os.path.join(root, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w", encoding="utf-8") as handle:
        json.dump(data, handle)


def named(username, stamp):
    return {"timestamp": stamp, "media": [], "fbid": "1",
            "label_values": [{"label": "URL", "value": ""}, {"label": "Name", "value": "Somebody"}, {"label": "Username", "value": username}]}


def owned(username, stamp):
    owner = {"title": "Owner", "dict": [{"title": "", "dict": [{"label": "URL", "value": ""}, {"label": "Name", "value": "N"},
                                                                  {"label": "Username", "value": username}]}]}
    return {"timestamp": stamp, "media": [], "fbid": "2",
            "label_values": [{"label": "URL", "value": "u", "href": "u"}, {"label": "Caption", "value": "never read"}, owner]}


def make(root):
    follows = "connections/followers_and_following/"
    put(root, follows + "following.json", {"relationships_following": [
        {"title": "anna", "string_list_data": [{"href": "h", "timestamp": 1000}]},
        {"title": "Ben", "string_list_data": [{"href": "h", "timestamp": 2000}]}]})
    put(root, follows + "following_hashtags.json", {"relationships_following_hashtags": [
        {"title": "sunsets", "string_list_data": [{"href": "h", "timestamp": 5}]}]})
    put(root, follows + "followers_1.json", [
        {"title": "", "media_list_data": [], "string_list_data": [{"href": "h", "value": "anna", "timestamp": 1500}]}])
    put(root, follows + "followers_2.json", [
        {"title": "", "media_list_data": [], "string_list_data": [{"href": "h", "value": "cleo", "timestamp": 2500}]}])
    put(root, follows + "close_friends.json", [named("anna", 3000)])
    put(root, follows + "recently_unfollowed_profiles.json", [named("dora", 4000)])
    put(root, follows + "pending_follow_requests.json", [named("emil", 4100)])
    put(root, follows + "blocked_profiles.json", [named("finn", 4200)])
    # One entry, not a list of them.
    put(root, follows + "restricted_profiles.json", named("gus", 4300))
    activity = "your_instagram_activity/"
    put(root, activity + "likes/liked_posts.json", [owned("anna", 6000), owned("anna", 5000), owned("hana", 7000)])
    put(root, activity + "comments/post_comments_1.json", [
        {"media_list_data": [], "string_map_data": {"Comment": {"value": "never read"}, "Media Owner": {"value": "anna"}, "Time": {"timestamp": 6500}}},
        {"media_list_data": [], "string_map_data": {"Comment": {"value": "no owner"}, "Time": {"timestamp": 6600}}}])
    put(root, activity + "comments/reels_comments.json", {"comments_reels_comments": [
        {"string_map_data": {"Media Owner": {"value": "anna"}, "Time": {"timestamp": 6700}}}]})
    put(root, activity + "story_interactions/stories_viewed.json", [owned("anna", 8000)])
    put(root, "logged_information/recent_searches/profile_searches.json", {"searches_user": [
        {"title": "hana", "string_list_data": [{"href": "h", "timestamp": 9000}]}]})
    me, anna = "Me Myself", "Änna".encode("utf-8").decode("latin-1")
    put(root, activity + "messages/inbox/anna_1/message_1.json", {"participants": [{"name": anna}, {"name": me}], "title": anna, "messages": [
        {"sender_name": me, "timestamp_ms": 10_000_000, "content": "never read"}, {"sender_name": anna, "timestamp_ms": 12_000_000, "content": "x"}]})
    put(root, activity + "messages/inbox/ben_2/message_1.json", {"participants": [{"name": "Ben B"}, {"name": me}], "title": "Ben B", "messages": [
        {"sender_name": "Ben B", "timestamp_ms": 20_000_000}]})
    put(root, activity + "messages/inbox/group_3/message_1.json", {"participants": [{"name": "A"}, {"name": "B"}, {"name": me}], "title": "G", "messages": [
        {"sender_name": me, "timestamp_ms": 30_000_000}]})


def main():
    failures = []

    def check(what, got, wanted):
        if got != wanted:
            failures.append(f"{what}: got {got!r}, wanted {wanted!r}")

    with tempfile.TemporaryDirectory() as folder:
        root = os.path.join(folder, "instagram-somebody-2026-11-15-AbC123")
        make(root)
        target = os.path.join(folder, "facts.json")
        check("the tool's exit code", export.main(["export.py", root, target]), 0)
        with open(target, encoding="utf-8") as handle:
            written = handle.read()
        facts = json.loads(written)

    people, threads = facts["people"], facts["threads"]
    check("whose export it is", facts["account"], "somebody")
    check("the file's mark", facts["ohrtstagram_facts"], 1)
    check("anna", people.get("anna"), {"followed": 1000, "follows_you": 1500, "close_friend": 3000, "likes": [2, 5000, 6000],
                                        "comments": [2, 6500, 6700], "stories_seen": [1, 8000, 8000]})
    check("usernames are kept in lower case", people.get("ben"), {"followed": 2000})
    check("a follower from the second file", people.get("cleo"), {"follows_you": 2500})
    check("an unfollow", people.get("dora"), {"unfollowed": 4000})
    check("a request", people.get("emil"), {"requested": 4100})
    check("a block", people.get("finn"), {"blocked": 4200})
    check("the one restricted account", people.get("gus"), {"restricted": 4300})
    check("an account known only from a like and a search", people.get("hana"), {"likes": [1, 7000, 7000], "searched": 9000})
    check("a hashtag is not an account", "sunsets" in people, False)
    check("a conversation, under the name as written", threads.get("Änna"), {"threads": 1, "messages": 2, "yours": 1, "first": 10000, "last": 12000})
    check("a second conversation", threads.get("Ben B"), {"threads": 1, "messages": 1, "yours": 0, "first": 20000, "last": 20000})
    check("a group is left out, and so is the owner", sorted(threads), ["Ben B", "Änna"])
    check("no words from a message or a caption", "never read" in written, False)

    for failure in failures:
        print("FAIL", failure)
    print("export: all passed" if not failures else f"export: {len(failures)} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
