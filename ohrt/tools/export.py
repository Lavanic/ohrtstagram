#!/usr/bin/env python3
"""Turns an Instagram data export into the facts ohrtstagram shows on a profile.

  export.py <export folder> <facts file>

An export (Accounts Center, Download your information, as JSON) holds a date
for every follow in both directions, and every like, comment, story view and
message of yours. Instagram's app shows none of that on a profile, and does
not send it to the app either, so the export is the only place the past can
come from. This reads one and writes a single small file, account by
account, that ohrtstagram reads in (settings, Focus, Profiles).

Only dates and counts go into the file: no message text, no captions, no
contacts, nothing about logins or devices. It never leaves your machines.

The export's layout is not documented and changes. Each kind of file is read
for the shape it had in November 2026, and a file that is missing or shaped
otherwise is reported and skipped, not guessed at.
"""
import glob
import json
import os
import re
import sys
import time

VERSION = 1


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def mended(text):
    """The export writes UTF-8 names out byte by byte. This puts them back."""
    try:
        return text.encode("latin-1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return text


def labelled(values, label):
    """The entry with this label. One that holds other entries has a title instead."""
    for value in values or []:
        if value.get("label") == label or value.get("title") == label:
            return value
    return None


def username_of(item):
    """The account a labelled entry is about."""
    value = labelled(item.get("label_values"), "Username")
    return (value or {}).get("value") or None


def owner_of(item):
    """The account whose post or story a labelled entry is about."""
    owner = labelled(item.get("label_values"), "Owner")
    for entry in (owner or {}).get("dict") or []:
        value = labelled(entry.get("dict"), "Username")
        if value and value.get("value"):
            return value["value"]
    return None


def entries(data):
    """The list inside a file, whether it is the file or sits under one key."""
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        lists = [value for value in data.values() if isinstance(value, list)]
        if len(lists) == 1 and "label_values" not in data:
            return lists[0]
        return [data]
    return []


class Facts:
    def __init__(self):
        self.people = {}
        self.read = []
        self.skipped = []

    def person(self, username):
        return self.people.setdefault(username.strip().lower(), {})

    def date(self, username, key, stamp, earliest=True):
        """One date per account: the earliest seen, or the latest."""
        if not username or not stamp:
            return
        person = self.person(username)
        held = person.get(key)
        if held is None or (stamp < held if earliest else stamp > held):
            person[key] = int(stamp)

    def count(self, username, key, stamp):
        """How often, and from when to when: [count, first, last]."""
        if not username:
            return
        tally = self.person(username).setdefault(key, [0, 0, 0])
        tally[0] += 1
        if stamp:
            tally[1] = int(stamp) if not tally[1] else min(tally[1], int(stamp))
            tally[2] = max(tally[2], int(stamp))

    def each(self, root, pattern, what, handle):
        paths = sorted(glob.glob(os.path.join(root, pattern)))
        if not paths:
            self.skipped.append(f"{what}: no {pattern}")
            return
        total = 0
        for path in paths:
            try:
                for item in entries(load(path)):
                    if isinstance(item, dict) and handle(item):
                        total += 1
            except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
                self.skipped.append(f"{what}: {os.path.basename(path)} could not be read ({type(error).__name__})")
        self.read.append((what, total))


def read_export(root):
    facts = Facts()
    follows = "connections/followers_and_following/"

    def following(item):
        stamps = [entry.get("timestamp") for entry in item.get("string_list_data") or []]
        name = item.get("title") or next((entry.get("value") for entry in item.get("string_list_data") or [] if entry.get("value")), None)
        facts.date(name, "followed", min((stamp for stamp in stamps if stamp), default=None))
        return bool(name)

    def follower(item):
        for entry in item.get("string_list_data") or []:
            facts.date(entry.get("value") or item.get("title"), "follows_you", entry.get("timestamp"))
        return True

    def dated(key, earliest=True):
        def handle(item):
            facts.date(username_of(item), key, item.get("timestamp"), earliest)
            return bool(username_of(item))
        return handle

    def counted(key):
        def handle(item):
            facts.count(owner_of(item), key, item.get("timestamp"))
            return bool(owner_of(item))
        return handle

    def comment(item):
        fields = item.get("string_map_data") or {}
        owner = (fields.get("Media Owner") or {}).get("value")
        facts.count(owner, "comments", (fields.get("Time") or {}).get("timestamp"))
        return bool(owner)

    def search(item):
        for entry in item.get("string_list_data") or []:
            facts.date(item.get("title") or entry.get("value"), "searched", entry.get("timestamp"), earliest=False)
        return True

    # Not following*.json: that would take the hashtags you follow for accounts.
    facts.each(root, follows + "following.json", "accounts you follow", following)
    if glob.glob(os.path.join(root, follows + "following_[0-9]*.json")):
        facts.each(root, follows + "following_[0-9]*.json", "accounts you follow, continued", following)
    facts.each(root, follows + "followers_*.json", "accounts that follow you", follower)
    facts.each(root, follows + "close_friends.json", "close friends", dated("close_friend"))
    facts.each(root, follows + "recently_unfollowed_profiles.json", "accounts you unfollowed", dated("unfollowed", earliest=False))
    facts.each(root, follows + "pending_follow_requests.json", "follow requests you sent", dated("requested"))
    facts.each(root, follows + "blocked_profiles.json", "accounts you blocked", dated("blocked"))
    facts.each(root, follows + "restricted_profiles.json", "accounts you restricted", dated("restricted"))
    facts.each(root, follows + "hide_story_from.json", "accounts your story is hidden from", dated("story_hidden"))
    activity = "your_instagram_activity/"
    facts.each(root, activity + "likes/liked_posts.json", "posts you liked", counted("likes"))
    facts.each(root, activity + "comments/post_comments_*.json", "comments on posts", comment)
    facts.each(root, activity + "comments/reels_comments.json", "comments on reels", comment)
    facts.each(root, activity + "story_interactions/story_likes.json", "stories you liked", counted("story_likes"))
    facts.each(root, activity + "story_interactions/stories_viewed.json", "stories you saw", counted("stories_seen"))
    facts.each(root, activity + "saved/saved_posts.json", "posts you saved", counted("saved"))
    facts.each(root, "logged_information/recent_searches/profile_searches.json", "profiles you searched for", search)
    facts.people.pop("", None)
    return facts


def read_threads(root):
    """Message threads with one other person: how many messages, and when.

    Threads are named by the other person's display name, not their username,
    so that is what they are kept under. Two people with one name cannot be
    told apart, and the count of threads behind a name says when that is so.
    """
    paths = sorted(glob.glob(os.path.join(root, "your_instagram_activity/messages/inbox/*/message_*.json")))
    by_folder = {}
    for path in paths:
        by_folder.setdefault(os.path.dirname(path), []).append(path)
    threads, names = [], {}
    for folder, files in by_folder.items():
        people, stamps, senders = None, [], {}
        try:
            for path in files:
                data = load(path)
                people = people or [mended(person.get("name") or "") for person in data.get("participants") or []]
                for message in data.get("messages") or []:
                    stamp = message.get("timestamp_ms")
                    if stamp:
                        stamps.append(int(stamp) // 1000)
                    sender = mended(message.get("sender_name") or "")
                    senders[sender] = senders.get(sender, 0) + 1
        except (OSError, ValueError, AttributeError, TypeError):
            continue
        if people and len(people) == 2 and stamps:
            threads.append((people, stamps, senders))
            for name in people:
                names[name] = names.get(name, 0) + 1
    if not threads:
        return {}, None
    # The one name that is in every thread is the export's owner.
    me = max(names, key=names.get)
    kept = {}
    for people, stamps, senders in threads:
        other = next((name for name in people if name != me), None)
        if not other:
            continue
        entry = kept.setdefault(other, {"threads": 0, "messages": 0, "yours": 0, "first": 0, "last": 0})
        entry["threads"] += 1
        entry["messages"] += len(stamps)
        entry["yours"] += senders.get(me, 0)
        entry["first"] = min(stamps) if not entry["first"] else min(entry["first"], min(stamps))
        entry["last"] = max(entry["last"], max(stamps))
    return kept, me


def account_of(root):
    """Whose export this is, from the folder's own name: instagram-<username>-<date>-<id>."""
    match = re.fullmatch(r"instagram-(.+)-\d{4}-\d{2}-\d{2}-[A-Za-z0-9]+", os.path.basename(os.path.normpath(root)))
    return match.group(1).lower() if match else None


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    root, target = argv[1], argv[2]
    if not os.path.isdir(os.path.join(root, "connections")):
        print(f"error: {root} does not look like an unpacked Instagram export (no connections folder)", file=sys.stderr)
        return 1
    facts = read_export(root)
    threads, me = read_threads(root)
    account = account_of(root)
    made = max((os.path.getmtime(path) for path in glob.glob(os.path.join(root, "connections/followers_and_following/*.json"))), default=time.time())
    with open(target, "w", encoding="utf-8") as handle:
        json.dump({"ohrtstagram_facts": VERSION, "account": account, "exported": int(made), "people": facts.people, "threads": threads},
                  handle, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    print(f"export of {account or 'an account whose name the folder does not give'}")
    for what, total in facts.read:
        print(f"  {total:7d}  {what}")
    print(f"  {sum(entry['messages'] for entry in threads.values()):7d}  messages in {len(threads)} conversations with one other person")
    for line in facts.skipped:
        print(f"  skipped  {line}")
    print(f"{len(facts.people)} accounts, {os.path.getsize(target) // 1024} KB, written to {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
