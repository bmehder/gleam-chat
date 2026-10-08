import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/string

pub const history_limit = 100

pub const name_limit = 40

pub const message_limit = 1000

pub type Color {
  Teal
  Sky
  Violet
  Rose
  Amber
  Lime
  Orange
  Fuchsia
}

pub type Message {
  Message(user_key: String, name: String, color: Color, text: String)
}

pub type User {
  User(key: String, name: String, color: Color)
}

pub type Snapshot {
  Snapshot(users: List(User), messages: List(Message))
}

type State {
  State(
    next_color: Int,
    history: List(Message),
    users: List(User),
    subscribers: List(#(Subject(Snapshot), process.Monitor)),
  )
}

pub opaque type Command {
  Subscribe(subscriber: Subject(Snapshot), reply: Subject(Nil))
  Unsubscribe(subscriber: Subject(Snapshot), reply: Subject(Nil))
  SubscriberExited(process.Down)
  Register(name: String, reply: Subject(Result(User, String)))
  RemoveUser(key: String, reply: Subject(Nil))
  Clear(reply: Subject(Nil))
  History(reply: Subject(List(Message)))
  Send(
    user_key: String,
    text: String,
    reply: Subject(Result(List(Message), String)),
  )
}

pub fn start() -> actor.StartResult(Subject(Command)) {
  actor.new_with_initialiser(1000, fn(subject) {
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(SubscriberExited)
    Ok(
      actor.initialised(
        State(next_color: 0, history: [], users: [], subscribers: []),
      )
      |> actor.selecting(selector)
      |> actor.returning(subject),
    )
  })
  |> actor.on_message(handle)
  |> actor.start
}

pub fn history(room: Subject(Command)) -> List(Message) {
  actor.call(room, 1000, History)
}

pub fn send(
  room: Subject(Command),
  user_key user_key: String,
  text text: String,
) -> Result(List(Message), String) {
  actor.call(room, 1000, Send(user_key, text, _))
}

pub fn subscribe(
  room: Subject(Command),
  subscriber subscriber: Subject(Snapshot),
) -> Nil {
  actor.call(room, 1000, Subscribe(subscriber, _))
}

pub fn unsubscribe(
  room: Subject(Command),
  subscriber subscriber: Subject(Snapshot),
) -> Nil {
  actor.call(room, 1000, Unsubscribe(subscriber, _))
}

fn handle(state: State, command: Command) -> actor.Next(State, Command) {
  let history = state.history
  case command {
    Subscribe(subscriber, reply) -> {
      let subscribers = case
        list.any(state.subscribers, fn(entry) { entry.0 == subscriber })
      {
        True -> state.subscribers
        False -> {
          let assert Ok(pid) = process.subject_owner(subscriber)
          [#(subscriber, process.monitor(pid)), ..state.subscribers]
        }
      }
      // Snapshot and registration happen in the same serialized room command.
      // Later history notifications use this same subject, preserving order.
      process.send(subscriber, snapshot(state))
      process.send(reply, Nil)
      actor.continue(State(..state, subscribers:))
    }
    Unsubscribe(subscriber, reply) -> {
      let subscribers =
        list.filter(state.subscribers, fn(entry) {
          case entry.0 == subscriber {
            True -> {
              process.demonitor_process(entry.1)
              False
            }
            False -> True
          }
        })
      process.send(reply, Nil)
      actor.continue(State(..state, subscribers:))
    }
    SubscriberExited(down) -> {
      let subscribers =
        list.filter(state.subscribers, fn(entry) { entry.1 != down.monitor })
      actor.continue(State(..state, subscribers:))
    }
    Register(name, reply) -> {
      let name = string.trim(name)
      let key = string.lowercase(name)
      let outcome = case name {
        "" -> Error("Enter a display name.")
        _ ->
          case string.length(name) > name_limit {
            True -> Error("Name is too long.")
            False ->
              case find_user(state.users, key:) {
                Ok(_) -> Error("That name has been taken.")
                Error(_) ->
                  Ok(User(key:, name:, color: color_at(state.next_color)))
              }
          }
      }
      case outcome {
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
        Ok(user) -> {
          let state =
            State(
              ..state,
              next_color: state.next_color + 1,
              users: list.append(state.users, [user]),
            )
          broadcast(state)
          process.send(reply, Ok(user))
          actor.continue(state)
        }
      }
    }
    RemoveUser(key, reply) -> {
      let state =
        State(
          ..state,
          users: list.filter(state.users, fn(user) { user.key != key }),
        )
      broadcast(state)
      process.send(reply, Nil)
      actor.continue(state)
    }
    Clear(reply) -> {
      let state = State(..state, next_color: 0, users: [], history: [])
      broadcast(state)
      process.send(reply, Nil)
      actor.continue(state)
    }
    History(reply) -> {
      process.send(reply, history)
      actor.continue(state)
    }
    Send(user_key, text, reply) -> {
      let text = string.trim(text)
      let outcome = case find_user(state.users, key: user_key) {
        Error(_) -> Error("Choose a registered display name.")
        Ok(user) ->
          case text {
            "" -> Error("Write a message first.")
            _ ->
              case string.length(text) > message_limit {
                True -> Error("Message is too long.")
                False -> Ok(user)
              }
          }
      }
      case outcome {
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
        Ok(user) -> {
          let history =
            list.append(history, [
              Message(
                user_key: user.key,
                name: user.name,
                color: user.color,
                text:,
              ),
            ])
            |> list.drop(int_max(0, list.length(history) + 1 - history_limit))
          let state = State(..state, history:)
          broadcast(state)
          process.send(reply, Ok(history))
          actor.continue(state)
        }
      }
    }
  }
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

pub fn register(
  room: Subject(Command),
  name name: String,
) -> Result(User, String) {
  actor.call(room, 1000, Register(name, _))
}

pub fn clear(room: Subject(Command)) -> Nil {
  actor.call(room, 1000, Clear)
}

pub fn find_user(users: List(User), key key: String) -> Result(User, Nil) {
  list.find(users, fn(user) { user.key == key })
}

fn snapshot(state: State) -> Snapshot {
  Snapshot(users: state.users, messages: state.history)
}

fn broadcast(state: State) -> Nil {
  list.each(state.subscribers, fn(entry) {
    process.send(entry.0, snapshot(state))
  })
}

pub fn remove_user(room: Subject(Command), key key: String) -> Nil {
  actor.call(room, 1000, RemoveUser(key, _))
}

fn color_at(index: Int) -> Color {
  case index % 8 {
    0 -> Teal
    1 -> Sky
    2 -> Violet
    3 -> Rose
    4 -> Amber
    5 -> Lime
    6 -> Orange
    _ -> Fuchsia
  }
}
