// Identity lives in the URL. The BEAM validates it and announces changes.
const component = document.querySelector('lustre-server-component');
component.addEventListener('chat:user-selected', (event) => {
  const url = new URL(window.location.href);
  if (event.detail) url.searchParams.set('user', event.detail);
  else url.searchParams.delete('user');
  window.history.replaceState(null, '', url);
});

// Follow new messages only while reading at the bottom. Scrolling up stays put.
component.addEventListener('lustre:mount', () => {
  const root = component.shadowRoot ?? component;
  const scroll = root.querySelector('#message-scroll');
  if (!scroll) return;
  let followLatest = true;
  scroll.addEventListener('scroll', () => {
    followLatest = scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 80;
  });
  const observer = new MutationObserver(() => {
    if (followLatest) scroll.scrollTop = scroll.scrollHeight;
  });
  observer.observe(scroll, { childList: true, subtree: true, characterData: true });
  scroll.scrollTop = scroll.scrollHeight;
});
