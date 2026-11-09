#include <cassert>
#include <iostream>
#include "display.h"

using namespace display;
int main() {
  assert(hold_label("retry") == "长按重试" && hold_label("run") == "长按补跑" && hold_label("publish").empty());
  // Home: the entry row opens the Zhi.AI overview, and the microphone card opens device detail.
  Workbench w;
  assert(w.page() == Page::Home);
  w.tap(kTapNone, 0, 1000);
  w.tap(kTapAlerts, 0, 1000);  // overview-only targets do nothing at home
  w.tap(2, 0, 1000);
  assert(w.page() == Page::Home);
  w.tap(kTapDevice, 0, 1000);
  assert(w.page() == Page::Detail && w.index() == size_t(kRows));
  w.tap(0, 0, 2000);  // the device detail returns home
  assert(w.page() == Page::Home);
  w.tap(kTapHub, 0, 3000);
  assert(w.page() == Page::Overview);
  // Overview rows open cloud details, which return to the overview; the background goes home.
  w.tap(2, 0, 4000);
  assert(w.page() == Page::Detail && w.index() == 2);
  w.tap(0, 0, 5000);
  assert(w.page() == Page::Overview && w.index() == 0);
  w.tap(kTapHub, 0, 6000);
  assert(w.page() == Page::Home);
  w.tap(kTapHub, 0, 7000);
  w.tap(kTapHub, 0, 8000);
  assert(w.page() == Page::Home);

  // A new alert key opens the list once; the same key on the next poll does not.
  const std::vector<Alert> one = {{"task-failed:x", "tasks", "error", "X采集失败", 1, "", ""}};
  w.alerts(one, 9000);
  assert(w.page() == Page::Alerts);
  // A tap queued just before the switch was aimed at the previous page and is dropped.
  w.tap(0, 0, 9000 + kSettleMs - 1);
  assert(w.page() == Page::Alerts);
  w.tap(0, 0, 10000);  // alerts return to the overview
  assert(w.page() == Page::Overview);
  w.alerts(one, 11000);
  assert(w.page() == Page::Overview);
  w.tap(kTapAlerts, 0, 11000);
  assert(w.page() == Page::Alerts);
  w.tap(0, 0, 12000);
  // A resolved key that comes back later counts as new again.
  w.alerts({}, 13000);
  w.alerts(one, 14000);
  assert(w.page() == Page::Alerts);

  // Sixty seconds without a tap falls back home, from any page.
  w.tick(73999, 0);
  assert(w.page() == Page::Alerts);
  w.tick(74000, 0);
  assert(w.page() == Page::Home);
  w.tap(kTapHub, 0, 75000);
  w.tick(135000, 0);
  assert(w.page() == Page::Home);

  // Pairing or speech holds the page; the idle minute restarts when it ends.
  w.alerts({}, 135000);
  w.alerts(one, 136000);
  w.hold(200000);  // a long speech
  w.tick(200001, 0);
  assert(w.page() == Page::Alerts);
  w.tick(260000, 0);
  assert(w.page() == Page::Home);

  // Notice buttons step through pending cards (next past the last returns home, previous stops at the
  // first), the speed button keeps the card, the background returns home; a shrinking list also returns.
  w.push_notice(0, 2, 270000);
  assert(w.page() == Page::Notice && w.index() == 0);
  w.tap(kTapPrev, 2, 270500);
  assert(w.page() == Page::Notice && w.index() == 0);
  w.tap(kTapNext, 2, 271000);
  assert(w.page() == Page::Notice && w.index() == 1);
  w.tap(kTapSpeedCycle, 2, 271500);
  assert(w.page() == Page::Notice && w.index() == 1);
  w.tick(271500 + kIdleMs - 1, 2);  // a speed tap restarts the idle minute
  assert(w.page() == Page::Notice);
  w.tap(kTapPause, 2, 272000);
  assert(w.marquee_paused() && w.page() == Page::Notice);
  w.tap(kTapPause, 2, 272500);
  assert(!w.marquee_paused());
  w.tap(kTapPause, 2, 273000);
  w.tap(kTapNext, 2, 273500);
  assert(!w.marquee_paused() && w.page() == Page::Home);
  w.push_notice(1, 2, 274000);
  assert(w.page() == Page::Notice && w.index() == 1);
  w.tap(0, 2, 274500);
  w.push_notice(0, 2, 275000);
  assert(w.page() == Page::Notice && w.index() == 0);
  w.tap(kTapEnd, 2, 275500);
  assert(w.page() == Page::Home);
  w.push_notice(0, 2, 276000);
  w.tap(kTapPrev, 2, 331500);
  assert(w.page() == Page::Notice && w.index() == 0);
  w.tap(0, 2, 332000);
  assert(w.page() == Page::Home);
  w.push_notice(0, 2, 332500);
  w.tap(kTapNext, 2, 333000);
  w.tap(kTapNext, 2, 333500);
  assert(w.page() == Page::Home);
  w.push_notice(0, 2, 334000);
  w.tap(kTapNext, 2, 334500);
  w.tick(335000, 1);
  assert(w.page() == Page::Home);

  // A single pushed agent card opens and closes the same way.
  w.push_notice(0, 1, 336000);
  assert(w.page() == Page::Notice && w.index() == 0);
  w.tap(kTapEnd, 1, 336500);
  assert(w.page() == Page::Home);

  // Delivery order, not TTL, decides which agent card is new. A later short-lived card must not be
  // hidden behind an older card whose expiry is farther away.
  AgentNoticeQueue agent_queue;
  std::vector<Notice> agent_cards = {{"agent", "old", "旧消息", "长 TTL", 3600000}};
  assert(agent_queue.next(agent_cards, true) == 0);
  assert(agent_queue.next(agent_cards, true) == agent_cards.size());
  agent_cards.push_back({"agent", "new", "新消息", "短 TTL", 20000});
  assert(agent_queue.next(agent_cards, true) == 1);
  assert(agent_queue.next(agent_cards, true) == agent_cards.size());

  // Rebinding the device forgets seen alerts.
  w.reset();
  w.alerts(one, 280000);
  assert(w.page() == Page::Alerts);

  Notices n;
  assert(n.put("agent", "1", "消息", "内容", 30, 0));
  assert(n.put("agent", "2", "第二条", "内容", 60, 0));
  assert(n.put("agent", "1", "改过的消息", "内容", 10, 0));  // same key overwrites in place
  assert(n.size(9999) == 2 && n.get(0, 9999).title == "改过的消息");
  assert(n.get(0, 10000).title == "第二条" && n.size(10000) == 1);  // the first expires exactly at ttl
  assert(!n.active(60000));
  assert(!n.put("agent", "x", "坏", "", 65536, 0));
  for (int i = 0; i < 21; ++i) assert(n.put("agent", std::to_string(i), "满", "", 10, 0));
  assert(n.size(0) == 20 && n.get(0, 0).key == "1");  // overflow drops the oldest
  n.clear_agent();
  assert(n.size(0) == 0);
  assert(n.put("agent", "w", "回绕", "", 10, 0xfffffff0));
  assert(n.active(0x10));
  assert(!n.active(0x2710));
  std::cout << "display behavior tests passed\n";
}
