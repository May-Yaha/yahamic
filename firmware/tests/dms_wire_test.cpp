#include <cassert>
#include <iostream>
#include "dms_wire.h"
int main() {
  using namespace dmswire;
  dmswire::Broker b;
  assert(broker("mqtts://abc.iot.gz.baidubce.com:8883", b) && b.host == "abc.iot.gz.baidubce.com" && b.port == 8883);
  assert(broker("tls://IOT.gz.baidubce.com", b) && b.host == "iot.gz.baidubce.com" && b.port == 8883);
  assert(!broker("mqtts://evil.com/iot.gz.baidubce.com", b));
  assert(!broker("mqtts://xiot.gz.baidubce.com", b));           // 不是子域
  assert(!broker("mqtts://iot.gz.baidubce.com.evil.com", b));
  assert(!broker("mqtt://iot.gz.baidubce.com", b));             // 明文
  assert(!broker("mqtts://a.iot.gz.baidubce.com:0", b) && !broker("mqtts://a.iot.gz.baidubce.com:65536", b));
  assert(!broker("mqtts://a.iot.gz.baidubce.com:88/x", b) && !broker("mqtts://user@a.iot.gz.baidubce.com", b));

  const std::string dev = "0123456789abcdefgh";
  const std::string good = R"({"device_id":"0123456789abcdefgh","core_id":"core-1","secret":"s3cret","mqtt_url":"mqtts://c.iot.gz.baidubce.com:8883","command_topic":"ah/0123456789abcdefgh/v1/t/x/d/0123456789abcdefgh/e/0/cmd/down","since":1800000000})";
  auto j = wirejson::parse(good);
  Credential c;
  assert(credential(j.get(), c) && c.device_id == dev && c.since == 1800000000);
  assert(topic(c, "cmd/up") == "ah/0123456789abcdefgh/v1/t/x/d/0123456789abcdefgh/e/0/cmd/up");
  assert(username(c, 1800000001) == "thingidp@core-1|0123456789abcdefgh|1800000001|SHA256");
  assert(password_input(c, 1800000001) == "0123456789abcdefgh&1800000001&SHA256s3cret");
  const auto rejects = [&](const std::string& from, const std::string& to) {
    std::string s = good;
    s.replace(s.find(from), from.size(), to);
    auto bad = wirejson::parse(s);
    Credential out;
    return !credential(bad.get(), out);
  };
  assert(rejects("\"device_id\":\"0123456789abcdefgh\"", "\"device_id\":\"0123456789ABCDEFGH\""));
  assert(rejects("ah/0123456789abcdefgh/v1", "ah/other00000000000/v1"));  // 前缀必须是自己的设备号
  assert(rejects("/cmd/down", "/cmd/up"));
  assert(rejects("c.iot.gz.baidubce.com", "c.example.com"));
  assert(rejects("s3cret", ""));
  assert(rejects("core-1", "core 1"));

  assert(proof_message(dev, "abc") == "xpan-dms-iotcore-pop-v1\n0123456789abcdefgh\nabc");
  const uint8_t bytes[] = {0xfb, 0xff, 0xbf, 0x00, 0x01};
  assert(b64url_encode(bytes, 3) == "-_-_" && b64url_encode(bytes, 4) == "-_-_AA" && b64url_encode(bytes, 5) == "-_-_AAE");
  assert(b64url(std::string(16, 'a'), 16, 128) && !b64url(std::string(15, 'a'), 16, 128) && !b64url("aaaaaaaaaaaaaaa=", 16, 128));
  assert(device_id(dev) && !device_id(dev + "x"));

  Seen seen;
  const int64_t now = 1800000100;
  const auto verdict = [&](const char* json, int64_t since) {
    auto m = wirejson::parse(json);
    return judge(m.get(), now, since, seen);
  };
  assert(verdict(R"({"message_id":"m1","action":"get_status","ts":1800000090})", 0) == Verdict::run);
  assert(verdict(R"({"message_id":"m1","action":"get_status","ts":1800000090})", 0) == Verdict::drop);  // 重放
  assert(verdict(R"({"message_id":"m2","action":"mute","ts":1800000000})", 0) == Verdict::expired);
  assert(verdict(R"({"message_id":"m3","action":"unbind","ts":1700000500})", 1800000000) == Verdict::drop);  // 上一次绑定
  assert(verdict(R"({"message_id":"m4","ts":1800000090})", 0) == Verdict::drop);
  assert(verdict(R"({"message_id":"m5","action":"get_status"})", 0) == Verdict::run);
  for (int i = 0; i < 8; ++i) seen.add("x" + std::to_string(i));
  assert(seen.add("m1"));  // 环只记最近 8 个
  assert(std::string(link_state(false, true, true, false)).empty());
  assert(std::string(link_state(true, true, false, false)) == "connecting");  // 已连上但订阅未确认
  assert(std::string(link_state(true, true, true, false)) == "online");
  assert(std::string(link_state(true, false, false, true)) == "offline");
  // card 指令:内容由固件解析,不信任下发方。
  const auto parsed = [](const char* json, Card& out) {
    auto m = wirejson::parse(json);
    return card(m.get(), out);
  };
  Card k;
  assert(parsed(R"({"args":{"title":"AI 日报","body":"正文"}})", k) && !k.clear && k.title == "AI 日报" &&
         k.body == "正文" && k.ttl == kCardTtl);
  assert(parsed(R"({"args":{"title":"t","ttl_seconds":65535}})", k) && k.ttl == 65535 && k.body.empty());
  assert(parsed(R"({"args":{"clear":true}})", k) && k.clear);
  const std::string fits = "t" + std::string(508, 'b'), over = "t" + std::string(509, 'b');
  assert(parsed((R"({"args":{"title":"t","body":")" + fits.substr(1) + R"("}})").c_str(), k));
  assert(!parsed((R"({"args":{"title":"t","body":")" + over.substr(1) + R"("}})").c_str(), k));
  assert(!parsed(R"({"args":{"title":" "}})", k));
  assert(!parsed(R"({"args":{"title":"t","ttl_seconds":0}})", k));
  assert(!parsed(R"({"args":{"title":"t","ttl_seconds":65536}})", k));
  assert(!parsed(R"({"args":{"title":"t","body":7}})", k));
  assert(!parsed("{\"args\":{\"title\":\"\xff\"}}", k));  // cJSON 原样收下非法字节
  assert(!parsed(R"({"args":"{\"title\":\"t\"}"})", k));
  assert(!parsed(R"({"action":"card"})", k));
  std::cout << "dms_wire ok\n";
}
