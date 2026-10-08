import chat/client
import chat/room
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/uri
import lustre
import lustre/attribute
import lustre/element
import lustre/element/html
import lustre/server_component
import mist

pub fn main() -> Nil {
  let assert Ok(room) = room.start()
  let assert Ok(_) =
    mist.new(fn(req) { handle(req, room.data) })
    |> mist.bind("127.0.0.1")
    |> mist.port(8080)
    |> mist.start
  process.sleep_forever()
}

fn handle(
  req: request.Request(mist.Connection),
  room: process.Subject(room.Command),
) -> response.Response(mist.ResponseData) {
  case request.path_segments(req) {
    [] -> {
      let page =
        html.html([attribute.lang("en")], [
          html.head([], [
            html.title([], "Gleam chat"),
            html.meta([
              attribute.name("viewport"),
              attribute.content("width=device-width, initial-scale=1"),
            ]),
            html.link([
              attribute.rel("stylesheet"),
              attribute.href("/style.css"),
            ]),
            html.script(
              [attribute.type_("module"), attribute.src("/identity.js")],
              "",
            ),
            server_component.script(),
          ]),
          html.body([], [
            html.main([], [
              server_component.element(
                [
                  server_component.route(
                    "/chat?" <> option.unwrap(req.query, ""),
                  ),
                ],
                [
                  html.p([], [html.text("Connecting to the room…")]),
                ],
              ),
            ]),
          ]),
        ])
        |> element.to_string
      respond(200, "text/html; charset=utf-8", "<!doctype html>" <> page)
    }
    ["style.css"] -> {
      let assert Ok(file) =
        mist.send_file("priv/static/style.css", 0, option.None)
      response.new(200)
      |> response.set_header("content-type", "text/css")
      |> response.set_body(file)
    }
    ["identity.js"] -> {
      let assert Ok(file) =
        mist.send_file("priv/static/identity.js", 0, option.None)
      response.new(200)
      |> response.set_header("content-type", "text/javascript")
      |> response.set_body(file)
    }
    ["chat"] -> socket(req, room)
    _ -> respond(404, "text/plain", "Not found")
  }
}

fn respond(
  status: Int,
  content_type: String,
  body: String,
) -> response.Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", content_type)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn socket(
  req: request.Request(mist.Connection),
  room: process.Subject(room.Command),
) -> response.Response(mist.ResponseData) {
  mist.websocket(
    req,
    on_init: fn(_) {
      let assert Ok(runtime) =
        lustre.start_server_component(client.app(), #(room, selected_user(req)))
      let subject = process.new_subject()
      let selector = process.new_selector() |> process.select(subject)
      lustre.send(runtime, server_component.register_subject(subject))
      #(runtime, Some(selector))
    },
    handler: fn(runtime, message, connection) {
      case message {
        mist.Text(text) -> {
          case json.parse(text, server_component.runtime_message_decoder()) {
            Ok(message) -> lustre.send(runtime, message)
            Error(_) -> Nil
          }
          mist.continue(runtime)
        }
        mist.Custom(message) -> {
          let text =
            message |> server_component.client_message_to_json |> json.to_string
          case mist.send_text_frame(connection, text) {
            Ok(_) -> mist.continue(runtime)
            Error(_) -> mist.stop()
          }
        }
        mist.Closed | mist.Shutdown -> mist.stop()
        mist.Binary(_) -> mist.continue(runtime)
      }
    },
    on_close: fn(runtime) { lustre.send(runtime, lustre.shutdown()) },
  )
}

fn selected_user(req: request.Request(mist.Connection)) -> String {
  let query =
    req.query |> option.unwrap("") |> uri.parse_query |> result.unwrap([])
  query
  |> list.find(fn(pair) { pair.0 == "user" })
  |> result.map(fn(pair) { pair.1 })
  |> result.unwrap("")
}
