import chat/room
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import lustre
import lustre/attribute
import lustre/effect
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import lustre/server_component

pub type Model {
  Model(
    room: Subject(room.Command),
    name: String,
    selected_user: String,
    users: List(room.User),
    draft: String,
    messages: List(room.Message),
    error: String,
  )
}

pub type Msg {
  ClientCreatedSubscription(Subject(room.Snapshot))
  RoomPublishedState(room.Snapshot)
  UserChangedName(String)
  UserChangedDraft(String)
  UserSubmittedName
  UserSelectedName(String)
  RoomReturnedRegistration(Result(room.User, String))
  UserRemovedName(String)
  UserRequestedReset
  UserSubmittedMessage
  RoomReturnedSendResult(Result(List(room.Message), String))
}

pub fn app() -> lustre.App(#(Subject(room.Command), String), Model, Msg) {
  lustre.component(init:, update:, view:, options: [])
}

fn init(
  arguments: #(Subject(room.Command), String),
) -> #(Model, effect.Effect(Msg)) {
  let #(room, selected_user) = arguments
  #(
    Model(
      selected_user:,
      users: [],
      room:,
      name: "",
      draft: "",
      messages: [],
      error: "",
    ),
    server_component.select(fn(dispatch, subject) {
      // Subscribe from update, after Lustre has queued selector installation.
      dispatch(ClientCreatedSubscription(subject))
      process.new_selector()
      |> process.select_map(subject, RoomPublishedState)
    }),
  )
}

fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    ClientCreatedSubscription(subscriber) -> #(
      model,
      effect.from(fn(_) { room.subscribe(model.room, subscriber:) }),
    )
    RoomPublishedState(state) -> {
      let selected_user = case
        room.find_user(state.users, key: model.selected_user)
      {
        Ok(_) -> model.selected_user
        Error(_) -> ""
      }
      #(
        Model(
          ..model,
          messages: state.messages,
          users: state.users,
          selected_user:,
        ),
        url_effect(selected_user),
      )
    }
    UserSelectedName(key) -> {
      case room.find_user(model.users, key:) {
        Ok(_) -> #(
          Model(..model, selected_user: key, error: ""),
          url_effect(key),
        )
        Error(_) -> #(
          Model(
            ..model,
            selected_user: "",
            error: "Choose a registered display name.",
          ),
          url_effect(""),
        )
      }
    }
    UserSubmittedName -> #(
      model,
      effect.from(fn(dispatch) {
        dispatch(
          RoomReturnedRegistration(room.register(model.room, name: model.name)),
        )
      }),
    )
    RoomReturnedRegistration(Ok(user)) -> {
      let key = case room.find_user(model.users, key: user.key) {
        Ok(_) -> user.key
        Error(_) -> ""
      }
      #(
        Model(..model, selected_user: key, name: "", error: ""),
        url_effect(key),
      )
    }
    RoomReturnedRegistration(Error(error)) -> #(
      Model(..model, error:),
      effect.none(),
    )
    UserRemovedName(key) -> #(
      model,
      effect.from(fn(_) { room.remove_user(model.room, key:) }),
    )
    UserRequestedReset -> #(
      Model(..model, name: "", draft: "", error: ""),
      effect.from(fn(_) { room.clear(model.room) }),
    )
    UserChangedName(name) -> #(Model(..model, name:), effect.none())
    UserChangedDraft(draft) -> #(Model(..model, draft:), effect.none())
    RoomReturnedSendResult(Ok(_)) -> #(
      Model(..model, draft: "", error: ""),
      effect.none(),
    )
    RoomReturnedSendResult(Error(error)) -> #(
      Model(..model, error:),
      effect.none(),
    )
    UserSubmittedMessage -> #(
      model,
      effect.from(fn(dispatch) {
        // The room alone validates and owns submitted messages.
        dispatch(
          RoomReturnedSendResult(room.send(
            model.room,
            user_key: model.selected_user,
            text: model.draft,
          )),
        )
      }),
    )
  }
}

pub fn view(model: Model) -> Element(Msg) {
  let selected_color = case
    room.find_user(model.users, key: model.selected_user)
  {
    Ok(user) -> color_class(user.color)
    Error(_) -> "text-neutral-400"
  }
  html.div(
    [
      attribute.class(
        "flex h-dvh flex-col bg-[#212121] text-neutral-100 md:flex-row",
      ),
    ],
    [
      html.aside(
        [
          attribute.class(
            "relative flex shrink-0 flex-col border-b border-white/5 bg-[#171717] p-4 md:w-64 md:border-r md:border-b-0",
          ),
        ],
        [
          html.div([attribute.class("flex items-center gap-3 pr-10")], [
            html.span(
              [
                attribute.class(
                  "grid h-9 w-9 place-items-center rounded-xl bg-white/10 text-lg",
                ),
              ],
              [html.text("◌")],
            ),
            html.div([], [
              html.h1(
                [attribute.class("text-sm font-semibold " <> selected_color)],
                [
                  html.text("Gleam chat"),
                ],
              ),
              html.p(
                [attribute.class("text-xs wrap-anywhere " <> selected_color)],
                [
                  html.text(
                    case room.find_user(model.users, key: model.selected_user) {
                      Ok(user) -> "Chatting as " <> user.name
                      Error(_) -> "No user selected"
                    },
                  ),
                ],
              ),
            ]),
          ]),
          html.details([attribute.class("text-sm")], [
            html.summary(
              [
                attribute.class(
                  "absolute right-4 top-4 grid h-9 w-9 cursor-pointer list-none place-items-center rounded-lg text-xl text-neutral-400 hover:bg-white/5 hover:text-white",
                ),
              ],
              [
                html.span([attribute.class("sr-only")], [
                  html.text("Manage users"),
                ]),
                html.span([attribute.attribute("aria-hidden", "true")], [
                  html.text("⋯"),
                ]),
              ],
            ),
            html.p(
              [
                attribute.class(
                  "mt-4 mb-2 text-xs font-medium text-neutral-400",
                ),
              ],
              [html.text("Choose user")],
            ),
            case model.users {
              [] ->
                html.p([attribute.class("py-2 text-xs text-neutral-500")], [
                  html.text("No users yet. Create a name below."),
                ])
              _ -> html.text("")
            },
            html.ul(
              [attribute.class("my-2 space-y-1")],
              list.map(model.users, fn(user) {
                html.li(
                  [
                    attribute.class(
                      "flex items-center gap-1 rounded-lg "
                      <> case user.key == model.selected_user {
                        True -> "bg-white/10"
                        False -> "hover:bg-white/5"
                      },
                    ),
                  ],
                  [
                    html.button(
                      [
                        attribute.type_("button"),
                        attribute.attribute(
                          "aria-label",
                          "Choose " <> user.name,
                        ),
                        attribute.attribute(
                          "aria-pressed",
                          case user.key == model.selected_user {
                            True -> "true"
                            False -> "false"
                          },
                        ),
                        attribute.class(
                          "flex min-w-0 flex-1 items-center gap-2 rounded-lg px-3 py-2.5 text-left focus-visible:outline-2 focus-visible:outline-white "
                          <> color_class(user.color),
                        ),
                        event.on_click(UserSelectedName(user.key)),
                      ],
                      [
                        html.span([attribute.class("min-w-0 flex-1 truncate")], [
                          html.text(user.name),
                        ]),
                        html.span(
                          [
                            attribute.attribute("aria-hidden", "true"),
                            attribute.class("w-4 text-center"),
                          ],
                          [
                            html.text(case user.key == model.selected_user {
                              True -> "✓"
                              False -> ""
                            }),
                          ],
                        ),
                      ],
                    ),
                    html.button(
                      [
                        attribute.type_("button"),
                        attribute.attribute(
                          "aria-label",
                          "Remove " <> user.name,
                        ),
                        attribute.title("Remove " <> user.name),
                        attribute.class(
                          "h-8 w-8 shrink-0 rounded-md text-lg text-neutral-500 hover:bg-white/10 hover:text-red-300 focus-visible:outline-2 focus-visible:outline-white",
                        ),
                        event.on_click(UserRemovedName(user.key)),
                      ],
                      [html.text("×")],
                    ),
                  ],
                )
              }),
            ),
            html.form(
              [
                attribute.class("mt-3 pb-3"),
                event.on_submit(fn(_) { UserSubmittedName }),
              ],
              [
                html.label([attribute.class("block text-xs text-neutral-400")], [
                  html.text("Display name"),
                  html.input([
                    attribute.class(
                      "mt-2 w-full rounded-lg border border-white/10 bg-[#242424] px-3 py-2.5 text-sm outline-none focus:border-neutral-500",
                    ),
                    attribute.name("display-name"),
                    attribute.placeholder("Add a display name"),
                    attribute.value(model.name),
                    attribute.maxlength(room.name_limit),
                    event.on_input(UserChangedName),
                  ]),
                ]),
                html.button(
                  [
                    attribute.type_("submit"),
                    attribute.class(
                      "mt-3 w-full rounded-lg bg-white/10 px-3 py-2 text-sm hover:bg-white/15",
                    ),
                  ],
                  [html.text("Create user")],
                ),
              ],
            ),
            html.button(
              [
                attribute.type_("button"),
                attribute.class(
                  "mt-1 rounded-md px-2 py-2 text-xs text-neutral-500 hover:bg-white/5 hover:text-neutral-300",
                ),
                event.on_click(UserRequestedReset),
              ],
              [html.text("Clear users and chats")],
            ),
          ]),
        ],
      ),
      html.section(
        [attribute.class("relative flex min-h-0 min-w-0 flex-1 flex-col")],
        [
          html.header(
            [
              attribute.class(
                "flex h-16 shrink-0 items-center justify-between px-6",
              ),
            ],
            [
              html.h2(
                [attribute.class("text-lg font-medium text-neutral-200")],
                [html.text("One room")],
              ),
              html.span(
                [
                  attribute.class(
                    "rounded-full border border-white/10 px-3 py-1 text-xs text-neutral-400",
                  ),
                ],
                [html.text("Plain-text chat")],
              ),
            ],
          ),
          html.div(
            [
              attribute.id("message-scroll"),
              attribute.class(
                "min-h-0 flex-1 overflow-y-auto overscroll-contain px-4 pb-48 md:px-8",
              ),
            ],
            [
              case model.messages {
                [] ->
                  html.div(
                    [
                      attribute.class(
                        "mx-auto flex min-h-64 max-w-3xl flex-col items-center justify-center text-center",
                      ),
                    ],
                    [
                      html.h3(
                        [
                          attribute.class(
                            "mb-3 text-3xl font-medium tracking-tight",
                          ),
                        ],
                        [html.text("Start a conversation")],
                      ),
                      html.p(
                        [
                          attribute.class(
                            "max-w-sm text-sm leading-6 text-neutral-400",
                          ),
                        ],
                        [
                          html.text(
                            "Choose a name or create one in Manage users, then say hello to the room.",
                          ),
                        ],
                      ),
                    ],
                  )
                _ ->
                  html.ul(
                    [
                      attribute.id("messages"),
                      attribute.class("mx-auto max-w-3xl space-y-7 py-6"),
                    ],
                    list.map(model.messages, fn(message) {
                      html.li(
                        [
                          attribute.class(
                            "flex flex-col gap-2 "
                            <> case message.user_key == model.selected_user {
                              True -> "items-end"
                              False -> "items-start"
                            },
                          ),
                        ],
                        [
                          html.strong(
                            [
                              attribute.class(
                                "text-xs font-medium "
                                <> color_class(message.color),
                              ),
                            ],
                            [html.text(message.name)],
                          ),
                          html.p(
                            [
                              attribute.class(
                                "max-w-[85%] whitespace-pre-wrap rounded-2xl bg-[#2b2b2b] px-5 py-3 text-[15px] leading-7 wrap-anywhere",
                              ),
                            ],
                            [html.text(message.text)],
                          ),
                        ],
                      )
                    }),
                  )
              },
            ],
          ),
          html.footer(
            [
              attribute.class(
                "absolute inset-x-0 bottom-0 bg-[#212121] px-4 pb-5 pt-3 md:px-8",
              ),
            ],
            [
              html.div([attribute.class("mx-auto max-w-3xl")], [
                html.form(
                  [
                    attribute.id("composer"),
                    attribute.class(
                      "flex items-center gap-3 rounded-3xl border border-white/10 bg-[#303030] p-3 pl-5 shadow-lg focus-within:border-neutral-500",
                    ),
                    event.on_submit(fn(_) { UserSubmittedMessage }),
                  ],
                  [
                    html.label(
                      [
                        attribute.class("sr-only"),
                        attribute.for("message-input"),
                      ],
                      [html.text("Message")],
                    ),
                    html.input([
                      attribute.id("message-input"),
                      attribute.class(
                        "min-w-0 flex-1 bg-transparent py-2 text-[15px] outline-none placeholder:text-neutral-400",
                      ),
                      attribute.name("message"),
                      attribute.placeholder("Message the room"),
                      attribute.value(model.draft),
                      attribute.maxlength(room.message_limit),
                      event.on_input(UserChangedDraft),
                    ]),
                    html.button(
                      [
                        attribute.type_("submit"),
                        attribute.attribute("aria-label", "Send"),
                        attribute.title("Send message"),
                        attribute.class(
                          "grid h-10 w-10 shrink-0 place-items-center rounded-full bg-white text-xl font-semibold text-neutral-900 hover:bg-neutral-200",
                        ),
                      ],
                      [html.text("↑")],
                    ),
                  ],
                ),
                html.p(
                  [
                    attribute.role("alert"),
                    attribute.class(
                      "min-h-5 pt-2 text-center text-xs text-red-300",
                    ),
                  ],
                  [html.text(model.error)],
                ),
                html.p(
                  [attribute.class("text-center text-[11px] text-neutral-500")],
                  [
                    html.text(
                      "Shared with everyone in this room. History is temporary.",
                    ),
                  ],
                ),
              ]),
            ],
          ),
        ],
      ),
    ],
  )
}

fn url_effect(key: String) -> effect.Effect(Msg) {
  server_component.emit("chat:user-selected", json.string(key))
}

fn color_class(color: room.Color) -> String {
  case color {
    room.Teal -> "text-teal-300"
    room.Sky -> "text-sky-300"
    room.Violet -> "text-violet-300"
    room.Rose -> "text-rose-300"
    room.Amber -> "text-amber-300"
    room.Lime -> "text-lime-300"
    room.Orange -> "text-orange-300"
    room.Fuchsia -> "text-fuchsia-300"
  }
}
