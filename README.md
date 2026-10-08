# gleam-chat

## Milestone 2: shared live room

From this project directory:

```sh
cd /Users/bradleymehder/Developer/Gleam/chat
gleam deps download
gleam test
gleam run
```

Open http://127.0.0.1:8080. Create a display name with Enter or Create user, or select an existing user.
Enter a message and press Send (or Enter in the message field). Stop the server with Ctrl-C.
Gleam and Erlang/OTP must be installed. No Node build is needed.

### Responsibilities

- `src/chat/room.gleam`: one BEAM actor owns the last 100 messages and
  serializes sends and subscriptions. It trims names/text, rejects empty inputs, and limits names
  to 40 characters and messages to 1,000 characters.
- `src/chat/client.gleam`: one Lustre component per WebSocket owns that client's
  name being entered, selected user key, message draft, error, and a shared-state
  snapshot for rendering.
- `src/chat.gleam`: starts the room once, serves the page and stylesheet,
  and bridges Mist WebSockets to Lustre on the same localhost port (8080).
- `priv/static/style.css`: the single stylesheet.

Component init, update, view, and effects all execute on the BEAM. Init creates
an effect that installs a room-history selector and subscribes. Sending runs an effect that calls the room actor and dispatches
its result back to the component. Only Lustre's bundled client runtime runs in
JavaScript: it captures DOM events and applies the server's DOM patches. No
application Gleam is compiled for the browser. The initial HTTP page provides
the component host; connecting delivers its initial view over the WebSocket.

The network carries HTML/CSS/runtime JavaScript over HTTP, then JSON DOM events
(including input values and submit data) toward the server and initial virtual
DOM/patches toward the browser. Names and message text are rendered through
`html.text`, never raw HTML.

Reloading creates a fresh client component: input drafts reset, while the
selected user is restored from the URL if still registered. Room users and
history survive. Closing/disconnecting tears down the component without
stopping the room. A reconnect creates fresh per-client state; explicit
connection/draft behavior is milestone 3. Restarting the server clears registered users and all
in-memory history.

### Subscriptions and milestone boundary

The room registers a subscriber and sends its current users and history in one serialized
command. Later sends broadcast the full bounded history to each subscriber on
the same subject. BEAM message ordering ensures the snapshot precedes subsequent
updates, so connection setup cannot miss changes. There is no participant cap.

The client first creates a subject and asks Lustre to install its selector.
It dispatches `ClientCreatedSubscription`; handling that message subscribes to
the room. Lustre has already queued selector installation before the room can
send the snapshot. Subscribing inside the selector callback would allow the
snapshot to arrive too early and be discarded by the runtime.

Only `RoomPublishedState` updates the rendered users and message list. Send success
clears the submitting client's draft and error; its returned history is not
applied separately, avoiding a stale reply overwriting a newer notification.
User selection and drafts remain private to each client component; registered
users are shared.

The room monitors each subscriber's owning BEAM process. Mist shuts down the
client component when its WebSocket closes; the room then removes that dead
subscription. Explicit unsubscribe is also available. Neither path destroys
the room or clears its history. Membership is deduplicated by subject.

Milestone 3 remains deferred: connection indicators, inspecting WebSocket
traffic/DOM patches, and explicit reconnect and unsent-draft behavior.

### Verification

`gleam test` covers blank inputs, length limits, history order, and eviction of
the oldest messages. Subscription tests cover initial snapshots, broadcasts to
multiple subjects, duplicate registration, rejected sends, explicit unsubscribe,
concurrent sends during a join, and room survival after a subscriber exits.

Two browser clients were checked in both directions. A late join received
existing history before any input. Incoming messages preserved the other
client's name and unsent draft. Reloading cleared the reloaded client's name and
draft, restored history, and resumed live updates. Milestone 1 also verified
literal HTML-like text and empty-message rejection.

`build/` and Erlang crash dumps are ignored. `gleam.toml` and `manifest.toml`
should be tracked so dependency versions remain reproducible.

## Temporary demo users

Type a display name and press Enter or Create user. The room trims whitespace,
uses the lowercase name as its key, and rejects an existing key with
"That name has been taken." The original trimmed capitalization is retained
for display. Select an existing user to return as that name, including from
another device connected to the same running server.

The URL identifies the selection: creating ` Brad ` sets `/?user=brad`.
Spaces and other characters are query-encoded. The HTTP page passes this key
to the WebSocket component; the room snapshot validates it against registered
users. Unknown keys are deselected and removed from the URL.

`priv/static/identity.js` is a small browser bridge: it listens for the
BEAM component's `chat:user-selected` event and updates the current URL using
`history.replaceState`. It uses no local storage or cookies. The bridge loads
before Lustre's client runtime. Application state and validation remain on the
BEAM. Registering broadcasts users and history atomically; sending resolves the
selected key on the server and stores the registered display name with the text.

Clear users and chats is available to every client. It clears both shared
lists in one room command, preserves subscriptions, resets invalid selections,
and removes the user query parameter in connected browsers. Unsent drafts in
other clients remain local; the client pressing Clear also clears its drafts.
Individual removal is available through the × beside a user in Manage users.
It removes the registration, resets that user’s selections and URLs in connected
clients, and preserves all messages. The same name can be registered again.

Users and messages survive disconnects but not a server restart. These demo
users have no authentication or ownership. Deployment remains deferred.

Two browser clients verified Enter registration, duplicate rejection, shared
options, independent selections, URL restoration after reload, query encoding,
live messaging, and clearing both lists and URLs for all clients.

## Styling and scrolling

Tailwind CSS 4.3.0 is built locally using its official CLI. The browser loads
one compiled stylesheet, `priv/static/style.css`; it does not load a Tailwind
CDN or compiler. `assets/style.css` is its source, explicitly scanning `src/`.
The compiled stylesheet is kept with the project so ordinary `gleam run` does
not require an npm build. Track both npm manifests and the compiled stylesheet;
`node_modules/` is ignored.

To edit styles, from this directory:

```sh
npm ci
npm run build:css
# Or keep a watcher running in a separate terminal:
npm run watch:css
```

The interface has a dark sidebar for users, a scrollable conversation area, and
a composer anchored to the bottom. Manage users contains registration and the
individual × actions. Click a name in the combined picker to select it; a
checkmark marks the active name. Clear users and chats remains subdued inside
Manage users, opened with the ⋯ beside the app title. On narrow screens the user controls sit above the conversation.

The small browser bridge also follows newly added messages while the reader
is at the bottom. Scrolling up suspends that behavior so incoming messages
leave the reader in place. Scroll back down to resume following. This is browser
presentation behavior; domain state, updates, and validation still run on the
BEAM. Nine tests pass, including removal preserving chat history and live
subscriptions. Two-client browser checks cover removal resetting selections
and URLs, message preservation, and the pinned composer during history scrolling.


Each registration receives a color from an eight-color palette, repeating without
limiting participants. The selected user's color matches the app title and
identity label. Your messages align right and everyone else's align left.
Messages retain their sender key, display name, and color when a user is removed.
