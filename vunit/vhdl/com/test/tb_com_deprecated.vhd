-- Test suite for deprecated parts of the com package
--
-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this file,
-- You can obtain one at http://mozilla.org/MPL/2.0/.
--
-- Copyright (c) 2017, Lars Asplund lars.anders.asplund@gmail.com

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;

library ieee;
use ieee.std_logic_1164.all;

use std.textio.all;

entity tb_com_deprecated is
  generic (
    runner_cfg : string);
end entity tb_com_deprecated;

architecture test_fixture of tb_com_deprecated is
  signal hello_world_received, start_receiver, start_server,
    start_server2, start_server3, start_subscribers : boolean := false;
  signal hello_subscriber_received                     : std_logic_vector(1 to 2) := "ZZ";
begin
  test_runner : process
    variable actor_to_be_found, actor_with_deferred_creation, actor_to_destroy,
      actor_to_destroy_copy, actor_to_keep, actor,
      self, receiver, server, deferred_actor, publisher, subscriber,
      limited_inbox, actor_with_max_inbox, actor_with_bounded_inbox : actor_t;
    variable status            : com_status_t;
    variable receipt, receipt2 : receipt_t;
    variable n_actors          : natural;
    variable message           : message_ptr_t;
    variable reply_message     : message_ptr_t;
    variable t_start, t_stop   : time;
    variable ack               : boolean;
  begin
    checker_init(display_format => verbose,
                 file_name      => join(output_path(runner_cfg), "error.csv"),
                 file_format    => verbose_csv);
    test_runner_setup(runner, runner_cfg);
    allow_timeout;
    allow_deprecated;

    while test_suite loop
      reset_messenger;
      self := create("test runner");
      if run("Test that a created actor can be destroyed") then
        actor_to_destroy := create("actor to destroy");
        actor_to_keep    := create("actor to keep");
        n_actors         := num_of_actors;
        destroy(actor_to_destroy, status);
        check(num_of_actors = n_actors - 1, "Expected one less actor");
        check(status = ok, "Expected destroy status to be ok");
        check(actor_to_destroy = null_actor_c, "Destroyed actor should be nullified");
        check(find("actor to destroy", false) = null_actor_c, "A destroyed actor should not be found");
        check(find("actor to keep", false) /= null_actor_c,
              "Actors other than the one destroyed must not be affected");
      elsif run("Expected to fail: Test that a non-existing actor cannot be destroyed") then
        actor := null_actor_c;
        destroy(actor, status);
      elsif run("Test that an actor can send a message to another actor") then
        start_receiver <= true;
        wait for 1 ns;
        receiver       := find("receiver");
        send(net, receiver, "hello world", receipt);
        check(receipt.status = ok, "Expected send to succeed");
        wait until hello_world_received for 1 ns;
        check(hello_world_received, "Expected ""hello world"" to be received at the server");
      elsif run("Test that an actor can send a message in response to another message from an a priori unknown actor") then
        start_server <= true;
        wait for 1 ns;
        server       := find("server");
        message      := compose("request", self);
        send(net, server, message, receipt);
        check(receipt.status = ok, "Expected send to succeed");
        receive(net, self, message);
        if check(message.status = ok, "Expected no receive problems") then
          check(message.payload.all = "request acknowledge", "Expected ""request acknowledge""");
        end if;
        delete(message);
      elsif run("Test that an actor can poll for incoming messages") then
        receive(net, self, message, 0 ns);
        check(message.payload = null, "Expected no message payload");
        check(message.status = timeout, "Expected timeout");
        send(net, self, self, "hello again", receipt);
        check(receipt.status = ok, "Expected send to succeed");
        receive(net, self, message, 0 ns);
        if check(message.status = ok, "Expected no problems with receive") then
          check(message.payload.all = "hello again", "Expected ""hello again""");
          check(message.sender = self, "Expected message from myself");
        end if;
        delete(message);
      elsif run("Test that an actor can publish messages to multiple subscribers") then
        publisher         := create("publisher");
        start_subscribers <= true;
        wait for 1 ns;
        publish(net, publisher, "hello subscriber", status);
        check(status = ok, "Expected publish to succeed");
        wait until hello_subscriber_received = "11" for 1 ns;
        check(hello_subscriber_received = "11", "Expected ""hello subscribers"" to be received at the subscribers");
      elsif run("Test that a subscriber can unsubscribe") then
        subscribe(self, self, status);
        check(status = ok, "Expected subscription to be ok");
        publish(net, self, "hello subscriber", status);
        check(status = ok, "Expected publish to succeed");
        receive(net, self, message, 0 ns);
        check(message.status = ok, "Expected no problems with receive");
        check(message.payload.all = "hello subscriber", "Expected a ""hello subscriber"" message");
        unsubscribe(self, self, status);
        publish(net, self, "hello subscriber", status);
        check(status = ok, "Expected publish to succeed");
        receive(net, self, message, 0 ns);
        check(message.status = timeout, "Expected no message");
      elsif run("Test that a destroyed subscriber is not addressed by the publisher") then
        subscriber := create("subscriber");
        subscribe(subscriber, self, status);
        check(status = ok, "Expected subscription to be ok");
        publish(net, self, "hello subscriber", status);
        check(status = ok, "Expected publish to succeed");
        receive(net, subscriber, message, 0 ns);
        if check(message.status = ok, "Expected no problems with receive") then
          check(message.payload.all = "hello subscriber", "Expected a ""hello subscriber"" message");
        end if;
        destroy(subscriber, status);
        check(status = ok, "Expected destroy status to be ok");
        publish(net, self, "hello subscriber", status);
        check(status = ok, "Expected publish to succeed. Got " & com_status_t'image(status) & ".");
      elsif run("Expected to fail: Test that an actor can only subscribe once to the same publisher") then
        subscribe(self, self, status);
        check(status = ok, "Expected subscription to be ok");
        subscribe(self, self, status);
      elsif run("Test that a client can wait for an out-of-order request reply") then
        start_server2 <= true;
        server        := find("server2");
        send(net, self, server, "request1", receipt);
        send(net, self, server, "request2", receipt2);

        receive_reply(net, self, receipt2.id, reply_message);
        check(reply_message.payload.all = "reply2", "Expected ""reply2""");
        check(reply_message.request_id = receipt2.id, "Expected request_id = " & integer'image(receipt2.id) &
              " but got " & integer'image(reply_message.request_id));
        receive_reply(net, self, receipt.id, reply_message);
        check(reply_message.payload.all = "reply1", "Expected ""reply1""");
        check(reply_message.request_id = receipt.id, "Expected request_id = " & integer'image(receipt.id) &
              " but got " & integer'image(reply_message.request_id));
        delete(reply_message);
      elsif run("Test that a synchronous request can be made") then
        start_server3 <= true;
        server        := find("server3");

        request(net, self, server, "request1", reply_message);
        check(reply_message.payload.all = "reply1", "Expected ""reply1""");
        delete(reply_message);

        request(net, self, server, "request2", ack, status);
        check(status = ok, "Expected request to succeed");
        check(ack, "Expected positive acknowledgement");

        request(net, self, server, "request3", ack, status);
        check(status = ok, "Expected request to succeed");
        check(not ack, "Expected negative acknowledgement");

        t_start := now;
        request(net, self, server, "request4", reply_message, 3 ns);
        check(reply_message.status = timeout, "Expected timeout");
        check(now - t_start = 3 ns, "Expected timeout after 3 ns");
        delete(reply_message);

        send(net, self, server, "A message", receipt);
        send(net, self, server, "This will sit in the inbox for 3 ns", receipt);
        t_start := now;
        request(net, self, server,
                "The send part will block for 3 ns, the receive part should timout after 2 to get a total of 5 ns",
                reply_message, 5 ns);
        check(reply_message.status = timeout, "Expected timeout");
        check(now - t_start = 5 ns, "Expected timeout after 5 ns");
        delete(reply_message);
      end if;
    end loop;

    test_runner_cleanup(runner);
    wait;
  end process;

  test_runner_watchdog(runner, 100 ms);

  receiver : process is
    variable self    : actor_t;
    variable message : message_ptr_t;
    variable status  : com_status_t;
  begin
    wait until start_receiver;
    self    := create("receiver");
    wait_for_messages(net, self, status);
    message := get_message(self);
    if check(message.payload.all = "hello world", "Expected ""hello world""") then
      hello_world_received <= true;
    end if;
    delete(message);
    wait;
  end process receiver;

  server : process is
    variable self    : actor_t;
    variable message : message_ptr_t;
    variable receipt : receipt_t;
  begin
    wait until start_server;
    self := create("server");
    receive(net, self, message);
    if check(message.payload.all = "request", "Expected ""request""") then
      send(net, message.sender, "request acknowledge", receipt);
      check(receipt.status = ok, "Expected send to succeed");
    end if;
    delete(message);
    wait;
  end process server;

  subscribers : for i in 1 to 2 generate
    process is
      variable self, publisher : actor_t;
      variable message         : message_ptr_t;
      variable status          : com_status_t;
    begin
      wait until start_subscribers;
      self      := create("subscriber " & integer'image(i));
      publisher := find("publisher");
      subscribe(self, publisher, status);
      receive(net, self, message);
      if check(message.payload.all = "hello subscriber", "Expected ""hello subscriber""") then
        hello_subscriber_received(i)     <= '1';
        hello_subscriber_received(3 - i) <= 'Z';
      end if;
      delete(message);
      wait;
    end process;
  end generate subscribers;

  server2 : process is
    variable self                               : actor_t;
    variable request_message1, request_message2 : message_ptr_t;
    variable receipt                            : receipt_t;
  begin
    wait until start_server2;
    self := create("server2");
    receive(net, self, request_message1);
    check(request_message1.payload.all = "request1", "Expected ""request1""");
    receive(net, self, request_message2);
    check(request_message2.payload.all = "request2", "Expected ""request2""");

    reply(net, request_message2.sender, request_message2.id, "reply2", receipt);
    check(receipt.status = ok, "Expected reply to succeed");
    reply(net, request_message1.sender, request_message1.id, "reply1", receipt);
    check(receipt.status = ok, "Expected reply to succeed");

    delete(request_message1);
    delete(request_message2);
    wait;
  end process server2;

  server3 : process is
    variable self            : actor_t;
    variable request_message : message_ptr_t;
    variable receipt         : receipt_t;
  begin
    wait until start_server3;
    self := create("server3", 1);

    receive(net, self, request_message);
    check(request_message.payload.all = "request1", "Expected ""request1""");
    reply(net, request_message.sender, request_message.id, "reply1", receipt);
    check(receipt.status = ok, "Expected reply to succeed");
    delete(request_message);

    receive(net, self, request_message);
    check(request_message.payload.all = "request2", "Expected ""request2""");
    acknowledge(net, request_message.sender, request_message.id, true, receipt);
    check(receipt.status = ok, "Expected acknowledge to succeed");
    delete(request_message);

    receive(net, self, request_message);
    acknowledge(net, request_message.sender, request_message.id, false, receipt);
    delete(request_message);

    receive(net, self, request_message);
    delete(request_message);

    receive(net, self, request_message);
    wait for 3 ns;
    receive(net, self, request_message);
    delete(request_message);
    wait;
  end process server3;

end test_fixture;
