import chat/client
import chat/room
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/string
import gleeunit
import lustre
import lustre/server_component

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn registration_validation_test() -> Nil {
  let assert Ok(r) = room.start()
  assert room.register(r.data, name: " \n ") == Error("Enter a display name.")
  let assert Ok(user) = room.register(r.data, name: " Brad ")
  assert user == room.User(key: "brad", name: "Brad", color: room.Teal)
  assert room.register(r.data, name: " BRAD ")
    == Error("That name has been taken.")
  let long_name = string.repeat("n", room.name_limit + 1)
  assert room.register(r.data, name: long_name) == Error("Name is too long.")
  let assert Ok(other) = room.register(r.data, name: " A & B ")
  assert other.key == "a & b"
}

pub fn send_validation_and_bounded_history_test() -> Nil {
  let assert Ok(r) = room.start()
  let assert Ok(_) = room.register(r.data, name: "Ada")
  assert room.send(r.data, user_key: "unknown", text: "hi")
    == Error("Choose a registered display name.")
  assert room.send(r.data, user_key: "ada", text: " \n ")
    == Error("Write a message first.")
  assert room.send(
      r.data,
      user_key: "ada",
      text: string.repeat("x", room.message_limit + 1),
    )
    == Error("Message is too long.")
  assert room.send(r.data, user_key: "ada", text: " <b>literal</b> ")
    == Ok([
      room.Message(
        user_key: "ada",
        name: "Ada",
        color: room.Teal,
        text: "<b>literal</b>",
      ),
    ])
  list.each(list.repeat(Nil, room.history_limit), fn(_) {
    let assert Ok(_) = room.send(r.data, user_key: "ada", text: "recent")
  })
  let history = room.history(r.data)
  assert list.length(history) == room.history_limit
  assert list.all(history, fn(message) { message.text == "recent" })
}

pub fn subscriptions_users_messages_and_reset_test() -> Nil {
  let assert Ok(r) = room.start()
  let first = process.new_subject()
  let second = process.new_subject()
  room.subscribe(r.data, subscriber: first)
  room.subscribe(r.data, subscriber: second)
  let empty = room.Snapshot(users: [], messages: [])
  assert process.receive(first, within: 1000) == Ok(empty)
  assert process.receive(second, within: 1000) == Ok(empty)
  let assert Ok(user) = room.register(r.data, name: "Ada")
  let registered = room.Snapshot(users: [user], messages: [])
  assert process.receive(first, within: 1000) == Ok(registered)
  assert process.receive(second, within: 1000) == Ok(registered)
  assert room.register(r.data, name: " ADA ")
    == Error("That name has been taken.")
  assert process.receive(first, within: 0) == Error(Nil)
  let assert Ok(messages) = room.send(r.data, user_key: "ada", text: "hello")
  let populated = room.Snapshot(users: [user], messages:)
  assert process.receive(first, within: 1000) == Ok(populated)
  assert process.receive(second, within: 1000) == Ok(populated)
  let late = process.new_subject()
  room.subscribe(r.data, subscriber: late)
  assert process.receive(late, within: 1000) == Ok(populated)
  room.clear(r.data)
  assert process.receive(first, within: 1000) == Ok(empty)
  assert process.receive(second, within: 1000) == Ok(empty)
  assert process.receive(late, within: 1000) == Ok(empty)
  assert room.history(r.data) == []
  assert room.send(r.data, user_key: "ada", text: "stale selection")
    == Error("Choose a registered display name.")
  assert room.register(r.data, name: "Ada") == Ok(user)
}

pub fn unsubscribe_and_duplicate_subscription_test() -> Nil {
  let assert Ok(r) = room.start()
  let subscriber = process.new_subject()
  room.subscribe(r.data, subscriber:)
  let assert Ok(_) = process.receive(subscriber, within: 1000)
  room.subscribe(r.data, subscriber:)
  let assert Ok(_) = process.receive(subscriber, within: 1000)
  let assert Ok(_) = room.register(r.data, name: "Ada")
  let assert Ok(_) = process.receive(subscriber, within: 1000)
  assert process.receive(subscriber, within: 0) == Error(Nil)
  room.unsubscribe(r.data, subscriber:)
  room.unsubscribe(r.data, subscriber:)
  room.clear(r.data)
  assert process.receive(subscriber, within: 0) == Error(Nil)
}

pub fn concurrent_join_has_ordered_history_test() -> Nil {
  let assert Ok(r) = room.start()
  let assert Ok(_) = room.register(r.data, name: "Ada")
  let done = process.new_subject()
  let subscriber = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      list.each(list.repeat(Nil, 20), fn(_) {
        let assert Ok(_) =
          room.send(r.data, user_key: "ada", text: "during join")
      })
      process.send(done, Nil)
    })
  room.subscribe(r.data, subscriber:)
  let assert Ok(snapshot) = process.receive(subscriber, within: 1000)
  assert process.receive(done, within: 1000) == Ok(Nil)
  assert list.length(room.history(r.data)) == 20
  list.each(
    list.repeat(Nil, 20 - list.length(snapshot.messages))
      |> list.index_map(fn(value, index) { #(index, value) }),
    fn(entry) {
      let assert Ok(state) = process.receive(subscriber, within: 1000)
      assert list.length(state.messages)
        == list.length(snapshot.messages) + entry.0 + 1
    },
  )
  assert process.receive(subscriber, within: 0) == Error(Nil)
}

pub fn subscriber_exit_preserves_room_test() -> Nil {
  let assert Ok(r) = room.start()
  let ready = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      room.subscribe(r.data, subscriber: process.new_subject())
      process.send(ready, Nil)
    })
  assert process.receive(ready, within: 1000) == Ok(Nil)
  let assert Ok(_) = room.register(r.data, name: "Ada")
  let assert Ok(history) =
    room.send(r.data, user_key: "ada", text: "room survives")
  assert room.history(r.data) == history
}

pub fn component_restores_user_and_history_without_dom_events_test() -> Nil {
  let assert Ok(r) = room.start()
  let assert Ok(_) = room.register(r.data, name: "Ada")
  let assert Ok(_) =
    room.send(r.data, user_key: "ada", text: "initial-history-marker")
  let assert Ok(runtime) =
    lustre.start_server_component(client.app(), #(r.data, "ada"))
  let updates = process.new_subject()
  lustre.send(runtime, server_component.register_subject(updates))
  assert receive_initial_history(updates, remaining: 8)
  lustre.send(runtime, lustre.shutdown())
}

fn receive_initial_history(
  updates: process.Subject(server_component.ClientMessage(client.Msg)),
  remaining remaining: Int,
) -> Bool {
  case remaining {
    0 -> False
    _ ->
      case process.receive(updates, within: 1000) {
        Error(_) -> False
        Ok(update) -> {
          let payload =
            update |> server_component.client_message_to_json |> json.to_string
          case string.contains(payload, "initial-history-marker") {
            True -> True
            False -> receive_initial_history(updates, remaining: remaining - 1)
          }
        }
      }
  }
}

pub fn removing_user_preserves_messages_and_subscriptions_test() -> Nil {
  let assert Ok(r) = room.start()
  let assert Ok(ada) = room.register(r.data, name: "Ada")
  let assert Ok(grace) = room.register(r.data, name: "Grace")
  let assert Ok(messages) =
    room.send(r.data, user_key: ada.key, text: "Keep this message")
  let subscriber = process.new_subject()
  room.subscribe(r.data, subscriber:)
  let assert Ok(_) = process.receive(subscriber, within: 1000)
  room.remove_user(r.data, key: ada.key)
  assert process.receive(subscriber, within: 1000)
    == Ok(room.Snapshot(users: [grace], messages:))
  assert room.history(r.data) == messages
  assert room.send(r.data, user_key: ada.key, text: "Removed user")
    == Error("Choose a registered display name.")
  room.remove_user(r.data, key: ada.key)
  assert process.receive(subscriber, within: 1000)
    == Ok(room.Snapshot(users: [grace], messages:))
  let assert Ok(_) = room.register(r.data, name: "Ada")
  let assert Ok(_) = process.receive(subscriber, within: 1000)
  let assert Ok(_) =
    room.send(r.data, user_key: grace.key, text: "Still subscribed")
  let assert Ok(snapshot) = process.receive(subscriber, within: 1000)
  assert list.length(snapshot.messages) == 2
}

pub fn user_colors_survive_removal_in_history_test() -> Nil {
  let assert Ok(r) = room.start()
  let assert Ok(ada) = room.register(r.data, name: "Ada")
  let assert Ok(brad) = room.register(r.data, name: "Brad")
  assert ada.color != brad.color
  let assert Ok(messages) =
    room.send(r.data, user_key: ada.key, text: "Keep my color")
  room.remove_user(r.data, key: ada.key)
  assert room.history(r.data) == messages
  let assert [message] = room.history(r.data)
  assert message.color == ada.color
  assert message.user_key == ada.key
}
