-- This file defines the com messenger which is responsible for housing the
-- messages in the system.
--
-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Copyright (c) 2017, Lars Asplund lars.anders.asplund@gmail.com

use work.com_types_pkg.all;
use work.com_support_pkg.all;

use std.textio.all;

package com_messenger_pkg is
  type mailbox_name_t is (inbox, outbox);

  type messenger_t is protected
    -----------------------------------------------------------------------------
    -- Handling of actors
    -----------------------------------------------------------------------------
    impure function create (name : string := ""; inbox_size : positive := positive'high) return actor_t;  --
    impure function find (name : string; enable_deferred_creation : boolean := true) return actor_t;

    procedure destroy (actor : inout actor_t);
    procedure reset_messenger;

    impure function num_of_actors return natural;
    impure function num_of_deferred_creations return natural;
    impure function unknown_actor (actor : actor_t) return boolean;
    impure function deferred (actor      : actor_t) return boolean;
    impure function is_full (actor : actor_t; mailbox_name : mailbox_name_t) return boolean;
    impure function inbox_size (actor    : actor_t) return natural;  --
    impure function subscriber_inbox_is_full (publisher : actor_t) return boolean;

    -----------------------------------------------------------------------------
    -- Send related subprograms
    -----------------------------------------------------------------------------
    procedure send (
      constant sender     : in  actor_t;
      constant receiver   : in  actor_t;
      constant mailbox_name : in mailbox_name_t;
      constant request_id : in  message_id_t;
      constant payload    : in  string;
      variable receipt    : out receipt_t);
    procedure publish (sender : actor_t; payload : string);

    -----------------------------------------------------------------------------
    -- Receive related subprograms
    -----------------------------------------------------------------------------
    impure function has_messages (actor                 : actor_t) return boolean;
    impure function get_first_message_payload (actor    : actor_t) return string;
    impure function get_first_message_sender (actor     : actor_t) return actor_t;
    impure function get_first_message_id (actor         : actor_t) return message_id_t;
    impure function get_first_message_request_id (actor : actor_t) return message_id_t;

    procedure delete_first_envelope (actor : actor_t);

    impure function has_reply_stash_message (
      actor      : actor_t;
      request_id : message_id_t := no_message_id_c)
      return boolean;                   --
    impure function get_reply_stash_message_payload (actor    : actor_t) return string;
    impure function get_reply_stash_message_sender (actor     : actor_t) return actor_t;
    impure function get_reply_stash_message_id (actor         : actor_t) return message_id_t;
    impure function get_reply_stash_message_request_id (actor : actor_t) return message_id_t;
    impure function find_and_stash_reply_message (
      actor : actor_t;
      request_id : message_id_t;
      mailbox_name : mailbox_name_t := inbox)
      return boolean;
    procedure clear_reply_stash (actor                        : actor_t);

    procedure subscribe (subscriber   : actor_t; publisher : actor_t);
    procedure unsubscribe (subscriber : actor_t; publisher : actor_t);

    ---------------------------------------------------------------------------
    -- Misc
    ---------------------------------------------------------------------------
    procedure allow_timeout;
    impure function timeout_is_allowed return boolean;
    procedure allow_deprecated;
    procedure deprecated (msg : string);

  end protected;
end package com_messenger_pkg;

package body com_messenger_pkg is
  type envelope_t;
  type envelope_ptr_t is access envelope_t;

  type envelope_t is record
    message       : message_t;
    next_envelope : envelope_ptr_t;
  end record envelope_t;
  type envelope_ptr_array is array (positive range <>) of envelope_ptr_t;

  type mailbox_t is record
    num_of_messages : natural;
    size : natural;
    first_envelope  : envelope_ptr_t;
    last_envelope   : envelope_ptr_t;
  end record mailbox_t;
  type mailbox_ptr_t is access mailbox_t;

  impure function create(size : natural := natural'high)
    return mailbox_ptr_t is
  begin
    return new mailbox_t'(0, size, null, null);
  end function create;

  type subscriber_item_t;
  type subscriber_item_ptr_t is access subscriber_item_t;

  type subscriber_item_t is record
    actor     : actor_t;
    next_item : subscriber_item_ptr_t;
  end record subscriber_item_t;

  type actor_item_t is record
    actor               : actor_t;
    name                : line;
    deferred_creation   : boolean;
    inbox               : mailbox_ptr_t;
    outbox               : mailbox_ptr_t;
    reply_stash         : envelope_ptr_t;
    subscribers         : subscriber_item_ptr_t;
  end record actor_item_t;

  type actor_item_array_t is array (natural range <>) of actor_item_t;
  type actor_item_array_ptr_t is access actor_item_array_t;

  type messenger_t is protected
    body
    variable null_actor_item_c : actor_item_t := (
      actor => null_actor_c,
      name => null,
      deferred_creation => false,
      inbox => create(0),
      outbox => create(0),
      reply_stash => null,
      subscribers => null);  --
    variable envelope_recycle_bin : envelope_ptr_array(1 to 1000);
    variable n_recycled_envelopes : natural                := 0;
    variable null_message         : message_t              := (0, ok, null_actor_c, null_actor_c, no_message_id_c, null);
    variable next_message_id      : message_id_t           := no_message_id_c + 1;
    variable timeout_allowed : boolean := false;
    variable deprecated_allowed : boolean := false;

    -----------------------------------------------------------------------------
    -- Handling of actors
    -----------------------------------------------------------------------------
    impure function new_envelope return envelope_ptr_t is
    begin
      if n_recycled_envelopes > 0 then
        n_recycled_envelopes                                         := n_recycled_envelopes - 1;
        envelope_recycle_bin(n_recycled_envelopes + 1).message       := null_message;
        envelope_recycle_bin(n_recycled_envelopes + 1).next_envelope := null;
        return envelope_recycle_bin(n_recycled_envelopes + 1);
      else
        return new envelope_t;
      end if;
    end new_envelope;

  procedure deallocate_envelope (ptr : inout envelope_ptr_t) is
  begin
    if (n_recycled_envelopes < envelope_recycle_bin'length) and (ptr /= null) then
      n_recycled_envelopes                       := n_recycled_envelopes + 1;
      envelope_recycle_bin(n_recycled_envelopes) := ptr;
      ptr                                        := null;
    else
      deallocate(ptr);
    end if;
  end deallocate_envelope;

  impure function init_actors return actor_item_array_ptr_t is
    variable ret_val : actor_item_array_ptr_t;
  begin
    ret_val    := new actor_item_array_t(0 to 0);
    ret_val(0) := null_actor_item_c;

    return ret_val;
  end function init_actors;

  variable actors               : actor_item_array_ptr_t := init_actors;

  impure function find_actor (name : string) return actor_t is
    variable ret_val : actor_t;
  begin
    for i in actors'reverse_range loop
      ret_val := actors(i).actor;
      if actors(i).name /= null then
        exit when actors(i).name.all = name;
      end if;
    end loop;

    return ret_val;
  end;

  impure function create_actor (
    name              :    string  := "";
    deferred_creation : in boolean := false;
    inbox_size        : in natural := natural'high)
    return actor_t is
    variable old_actors : actor_item_array_ptr_t;
  begin
    old_actors := actors;
    actors     := new actor_item_array_t(0 to actors'length);
    actors(0)  := null_actor_item_c;
    for i in old_actors'range loop
      actors(i) := old_actors(i);
    end loop;
    deallocate(old_actors);
    actors(actors'length - 1) := ((id => actors'length - 1), new string'(name),
                                  deferred_creation, create(inbox_size), create, null, null);

    return actors(actors'length - 1).actor;
  end function;

  impure function find (name : string; enable_deferred_creation : boolean := true) return actor_t is
    constant actor : actor_t := find_actor(name);
  begin
    if (actor = null_actor_c) and enable_deferred_creation then
      return create_actor(name, true, 1);
    else
      return actor;
    end if;
  end;

  impure function create (name : string := ""; inbox_size : positive := positive'high) return actor_t is
    variable actor : actor_t := find_actor(name);
  begin
    if actor = null_actor_c then
      actor := create_actor(name, false, inbox_size);
    elsif actors(actor.id).deferred_creation then
      actors(actor.id).deferred_creation   := false;
      actors(actor.id).inbox.size := inbox_size;
    else
      check_failed(duplicate_actor_name_error);
    end if;

    return actor;
  end;

  impure function is_subscriber (subscriber : actor_t; publisher : actor_t) return boolean is
    variable item : subscriber_item_ptr_t := actors(publisher.id).subscribers;
  begin
    while item /= null loop
      if item.actor = subscriber then
        return true;
      end if;
      item := item.next_item;
    end loop;

    return false;
  end;

  procedure remove_subscriber (subscriber : actor_t; publisher : actor_t) is
    variable item, previous_item : subscriber_item_ptr_t;
  begin
    item          := actors(publisher.id).subscribers;
    previous_item := null;
    while item /= null loop
      if item.actor = subscriber then
        if previous_item = null then
          actors(publisher.id).subscribers := item.next_item;
        else
          previous_item.next_item := item.next_item;
        end if;
        deallocate(item);
        return;
      end if;
      previous_item := item;
      item          := item.next_item;
    end loop;

    check_failed(not_a_subscriber_error);
  end;

  procedure destroy (actor : inout actor_t) is
    variable envelope           : envelope_ptr_t;
    variable item               : subscriber_item_ptr_t;
    variable unsubscribe_status : com_status_t;
  begin
    check(not unknown_actor(actor), unknown_actor_error);

    while actors(actor.id).inbox.first_envelope /= null loop
      envelope                              := actors(actor.id).inbox.first_envelope;
      actors(actor.id).inbox.first_envelope := envelope.next_envelope;
      deallocate(envelope.message.payload);
      deallocate_envelope(envelope);
    end loop;

    while actors(actor.id).subscribers /= null loop
      item                         := actors(actor.id).subscribers;
      actors(actor.id).subscribers := item.next_item;
      deallocate(item);
    end loop;

    for i in actors'range loop
      if is_subscriber(actor, actors(i).actor) then
        remove_subscriber(actor, actors(i).actor);
      end if;
    end loop;

    deallocate(actors(actor.id).name);
    deallocate(actors(actor.id).inbox);
    deallocate(actors(actor.id).outbox);
    actors(actor.id) := null_actor_item_c;
    actor            := null_actor_c;
  end;

  procedure reset_messenger is
  begin
    for i in actors'range loop
      if actors(i).actor /= null_actor_c then
        destroy(actors(i).actor);
      end if;
    end loop;
    deallocate(actors);
    actors          := init_actors;
    next_message_id := no_message_id_c + 1;
  end;

  impure function num_of_actors return natural is
    variable n_actors : natural := 0;
  begin
    for i in actors'range loop
      if actors(i).actor /= null_actor_c then
        n_actors := n_actors + 1;
      end if;
    end loop;

    return n_actors;
  end;

  impure function num_of_deferred_creations return natural is
    variable n_deferred_actors : natural := 0;
  begin
    for i in actors'range loop
      if actors(i).deferred_creation then
        n_deferred_actors := n_deferred_actors + 1;
      end if;
    end loop;

    return n_deferred_actors;
  end;

  impure function unknown_actor (actor : actor_t) return boolean is
  begin
    if (actor.id = 0) or (actor.id > actors'length - 1) then
      return true;
    elsif actors(actor.id).actor = null_actor_c then
      return true;
    end if;

    return false;
  end function unknown_actor;

  impure function deferred (actor : actor_t) return boolean is
  begin
    return actors(actor.id).deferred_creation;
  end function deferred;

  impure function is_full (actor : actor_t; mailbox_name : mailbox_name_t) return boolean is
  begin
    if mailbox_name = inbox then
      return actors(actor.id).inbox.num_of_messages >= actors(actor.id).inbox.size;
    else
      return actors(actor.id).outbox.num_of_messages >= actors(actor.id).outbox.size;
    end if;
  end function;

  impure function subscriber_inbox_is_full (publisher : actor_t) return boolean is
    variable item   : subscriber_item_ptr_t := actors(publisher.id).subscribers;
    variable result : boolean               := false;
  begin
    while item /= null loop
      result := is_full(item.actor, inbox);
      exit when result;
      item   := item.next_item;
    end loop;

    return result;
  end function;

  impure function inbox_size (actor : actor_t) return natural is
  begin
    return actors(actor.id).inbox.size;
  end function;

  -----------------------------------------------------------------------------
  -- Send related subprograms
  -----------------------------------------------------------------------------
  procedure send (
    constant sender     : in  actor_t;
    constant receiver   : in  actor_t;
    constant mailbox_name : in mailbox_name_t;
    constant request_id : in  message_id_t;
    constant payload    : in  string;
    variable receipt    : out receipt_t) is
    variable envelope : envelope_ptr_t;
    variable mailbox : mailbox_ptr_t;
  begin
    check(not is_full(receiver, mailbox_name), full_inbox_error);

    receipt.status              := ok;
    receipt.id                  := next_message_id;
    envelope                    := new_envelope;
    envelope.message.sender     := sender;
    envelope.message.receiver   := receiver;
    envelope.message.id         := next_message_id;
    envelope.message.request_id := request_id;
    write(envelope.message.payload, payload);
    next_message_id             := next_message_id + 1;

    mailbox := actors(receiver.id).inbox when mailbox_name = inbox else actors(receiver.id).outbox;
    mailbox.num_of_messages := mailbox.num_of_messages + 1;
    if mailbox.last_envelope /= null then
      mailbox.last_envelope.next_envelope := envelope;
    else
      mailbox.first_envelope := envelope;
    end if;
    mailbox.last_envelope := envelope;
  end;

  procedure publish (sender : actor_t; payload : string) is
    variable receipt         : receipt_t;
    variable subscriber_item : subscriber_item_ptr_t;
  begin
    check(not unknown_actor(sender), unknown_publisher_error);

    subscriber_item := actors(sender.id).subscribers;
    while subscriber_item /= null loop
      send(sender, subscriber_item.actor, inbox, no_message_id_c, payload, receipt);
      subscriber_item := subscriber_item.next_item;
    end loop;
  end;

  -----------------------------------------------------------------------------
  -- Receive related subprograms
  -----------------------------------------------------------------------------
  impure function has_messages (actor : actor_t) return boolean is
  begin
    return actors(actor.id).inbox.first_envelope /= null;
  end function has_messages;

  impure function get_first_message_payload (actor : actor_t) return string is
  begin
    if actors(actor.id).inbox.first_envelope /= null then
      return actors(actor.id).inbox.first_envelope.message.payload.all;
    else
      return "";
    end if;
  end;

  impure function get_first_message_sender (actor : actor_t) return actor_t is
  begin
    if actors(actor.id).inbox.first_envelope /= null then
      return actors(actor.id).inbox.first_envelope.message.sender;
    else
      return null_actor_c;
    end if;
  end;

  impure function get_first_message_id (actor : actor_t) return message_id_t is
  begin
    if actors(actor.id).inbox.first_envelope /= null then
      return actors(actor.id).inbox.first_envelope.message.id;
    else
      return no_message_id_c;
    end if;
  end;

  impure function get_first_message_request_id (actor : actor_t) return message_id_t is
  begin
    if actors(actor.id).inbox.first_envelope /= null then
      return actors(actor.id).inbox.first_envelope.message.request_id;
    else
      return no_message_id_c;
    end if;
  end;

  procedure delete_first_envelope (actor : actor_t) is
    variable first_envelope : envelope_ptr_t := actors(actor.id).inbox.first_envelope;
  begin
    if first_envelope /= null then
      deallocate(first_envelope.message.payload);
      actors(actor.id).inbox.first_envelope := first_envelope.next_envelope;
      deallocate_envelope(first_envelope);
      if actors(actor.id).inbox.first_envelope = null then
        actors(actor.id).inbox.last_envelope := null;
      end if;
      actors(actor.id).inbox.num_of_messages := actors(actor.id).inbox.num_of_messages - 1;
    end if;
  end;

  impure function has_reply_stash_message (
    actor      : actor_t;
    request_id : message_id_t := no_message_id_c)
    return boolean is
  begin
    if request_id = no_message_id_c then
      return actors(actor.id).reply_stash /= null;
    elsif actors(actor.id).reply_stash /= null then
      return actors(actor.id).reply_stash.message.request_id = request_id;
    else
      return false;
    end if;
  end function has_reply_stash_message;

  impure function get_reply_stash_message_payload (actor : actor_t) return string is
    variable envelope : envelope_ptr_t := actors(actor.id).reply_stash;
  begin
    if envelope /= null then
      return envelope.message.payload.all;
    else
      return "";
    end if;
  end;

  impure function get_reply_stash_message_sender (actor : actor_t) return actor_t is
    variable envelope : envelope_ptr_t := actors(actor.id).reply_stash;
  begin
    if envelope /= null then
      return envelope.message.sender;
    else
      return null_actor_c;
    end if;
  end;

  impure function get_reply_stash_message_id (actor : actor_t) return message_id_t is
    variable envelope : envelope_ptr_t := actors(actor.id).reply_stash;
  begin
    if envelope /= null then
      return envelope.message.id;
    else
      return no_message_id_c;
    end if;
  end;

  impure function get_reply_stash_message_request_id (actor : actor_t) return message_id_t is
    variable envelope : envelope_ptr_t := actors(actor.id).reply_stash;
  begin
    if envelope /= null then
      return envelope.message.request_id;
    else
      return no_message_id_c;
    end if;
  end;

  impure function find_and_stash_reply_message (
    actor : actor_t;
    request_id : message_id_t;
    mailbox_name : mailbox_name_t := inbox)
    return boolean is
    variable envelope          : envelope_ptr_t;
    variable previous_envelope : envelope_ptr_t := null;
    variable mailbox : mailbox_ptr_t;
  begin
    mailbox := actors(actor.id).inbox when mailbox_name = inbox else actors(actor.id).outbox;
    envelope := mailbox.first_envelope;

    while envelope /= null loop
      if envelope.message.request_id = request_id then
        actors(actor.id).reply_stash := envelope;
        if previous_envelope /= null then
          previous_envelope.next_envelope := envelope.next_envelope;
        else
          mailbox.first_envelope := envelope.next_envelope;
        end if;
        if mailbox.first_envelope = null then
          mailbox.last_envelope := null;
        end if;
        mailbox.num_of_messages := mailbox.num_of_messages - 1;
        return true;
      end if;
      previous_envelope := envelope;
      envelope          := envelope.next_envelope;
    end loop;

    return false;
  end function find_and_stash_reply_message;

  procedure clear_reply_stash (actor : actor_t) is
  begin
    deallocate(actors(actor.id).reply_stash.message.payload);
    deallocate(actors(actor.id).reply_stash);
  end procedure clear_reply_stash;

  procedure subscribe (subscriber : actor_t; publisher : actor_t) is
    variable new_subscriber : subscriber_item_ptr_t;
  begin
    check(not unknown_actor(subscriber), unknown_subscriber_error);
    check(not unknown_actor(publisher), unknown_publisher_error);
    check(not is_subscriber(subscriber, publisher), already_a_subscriber_error);

    new_subscriber                   := new subscriber_item_t'(subscriber, actors(publisher.id).subscribers);
    actors(publisher.id).subscribers := new_subscriber;
  end procedure subscribe;

  procedure unsubscribe (subscriber : actor_t; publisher : actor_t) is
  begin
    check(not unknown_actor(subscriber), unknown_subscriber_error);
    check(not unknown_actor(publisher), unknown_publisher_error);
    check(is_subscriber(subscriber, publisher), not_a_subscriber_error);

    remove_subscriber(subscriber, publisher);
  end procedure unsubscribe;

  -----------------------------------------------------------------------------
  -- Misc
  -----------------------------------------------------------------------------
  procedure allow_timeout is
  begin
    timeout_allowed := true;
  end procedure allow_timeout;

  impure function timeout_is_allowed return boolean is
  begin
    return timeout_allowed;
  end function timeout_is_allowed;

  procedure allow_deprecated is
  begin
    deprecated_allowed := true;
  end procedure allow_deprecated;

  procedure deprecated (msg : string) is
  begin
    check(deprecated_allowed, deprecated_interface_error, msg);
  end;
end protected body;

end package body com_messenger_pkg;
