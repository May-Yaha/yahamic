#include <cassert>
#include <iostream>
#include <fstream>
#include <filesystem>
#include "display_json.h"
int main() {
  using namespace wirejson;
  // desk_monitor structuredContent, same shape as yahaops-api domain/desk/monitor.go.
  const std::string valid = R"({"at":1800000000,"sections":[{"key":"tasks","title":"任务","available":true,"level":"error","summary":"1 项失败","lines":["X采集 · 失败2次"]},{"key":"collect","title":"采集","available":false,"summary":"无权限","lines":[]},{"key":"miniapp","title":"小程序","available":true,"level":"ok","summary":"今日 UV 12","lines":[],"trend":[1,2,3]}],"alerts":[{"key":"task-failed:x","section":"tasks","level":"error","title":"X采集失败","at":1799999000}]})";
  display::Monitor m;
  auto j = parse(valid);
  assert(monitor(j.get(), m) && m.at == 1800000000 && m.sections.size() == 3 && m.alerts.size() == 1);
  assert(m.sections[0].level == "error" && m.sections[0].lines[0] == "X采集 · 失败2次");
  assert(!m.sections[1].available && m.sections[1].level.empty() && m.sections[2].trend.size() == 3);
  assert(m.alerts[0].key == "task-failed:x" && m.alerts[0].at == 1799999000);
  assert(m.alerts[0].action.empty() && m.alerts[0].token.empty());
  // desk.operate pair is kept only when well-formed; anything else drops the pair, never the alert.
  const auto operate = [](const std::string& extra) {
    display::Monitor out;
    auto doc = parse(R"({"at":1,"sections":[],"alerts":[{"key":"k","section":"tasks","level":"error","title":"t","at":1)" + extra + "}]}");
    assert(monitor(doc.get(), out) && out.alerts.size() == 1);
    return out.alerts[0].action + " " + out.alerts[0].token;
  };
  assert(operate(R"(,"action":"retry","token":"eyJ.a-b_c")") == "retry eyJ.a-b_c");
  assert(operate(R"(,"action":"publish","token":"abc")") == " ");
  assert(operate(R"(,"action":"run")") == " ");
  assert(operate(R"(,"action":"run","token":"a b")") == " ");
  assert(operate(R"(,"action":"run","token":")" + std::string(257, 'a') + "\"") == " ");
  assert(operate(R"(,"action":"pause","token":)" + std::string("7")) == " ");
  const auto rejects = [](const char* json) {
    display::Monitor out;
    auto bad = parse(json);
    return !monitor(bad.get(), out);
  };
  assert(rejects(R"({"at":1,"sections":[{"key":"tasks","title":"任务","available":true,"level":"bad","summary":"","lines":[]}],"alerts":[]})"));
  assert(rejects(R"({"at":1,"sections":[{"key":"tasks","title":"任务","available":true,"summary":"","lines":[]}],"alerts":[]})"));  // available needs a level
  assert(rejects(R"({"at":1,"sections":[{"key":"tasks","title":"任务","available":true,"level":"ok","summary":"","lines":[1]}],"alerts":[]})"));
  assert(rejects(R"({"at":1,"sections":[],"alerts":[{"key":"k","section":"tasks","level":"ok","title":"t","at":1}]})"));
  // Trend values are bounded so int64 conversion and bar scaling cannot overflow.
  assert(rejects(R"({"at":1,"sections":[{"key":"miniapp","title":"小程序","available":true,"level":"ok","summary":"","lines":[],"trend":[1e300]}],"alerts":[]})"));
  assert(rejects(R"({"at":1,"sections":[{"key":"miniapp","title":"小程序","available":true,"level":"ok","summary":"","lines":[],"trend":[-1]}],"alerts":[]})"));
  assert(rejects(R"({"at":1,"sections":[],"alerts":[{"key":"k","section":"tasks","level":"warn","title":"t"}]})"));  // at is required
  assert(rejects(R"({"at":1.5,"sections":[],"alerts":[]})"));
  assert(rejects(R"({"at":1,"sections":[]})"));
  assert(rejects("{\"at\":1,\"sections\":[{\"key\":\"tasks\",\"title\":\"\xff\",\"available\":false,\"summary\":\"\",\"lines\":[]}],\"alerts\":[]}"));
  // Oversized but well-formed input is clipped, never trusted unbounded.
  {
    auto big = object();
    cJSON_AddNumberToObject(big.get(), "at", 1);
    auto* sections = cJSON_AddArrayToObject(big.get(), "sections");
    for (int i = 0; i < 7; ++i) {
      auto* s = cJSON_CreateObject();
      cJSON_AddStringToObject(s, "key", "k");
      cJSON_AddStringToObject(s, "title", "t");
      cJSON_AddBoolToObject(s, "available", true);
      cJSON_AddStringToObject(s, "level", "warn");
      cJSON_AddStringToObject(s, "summary", std::string(300, 'a').c_str());
      auto* lines = cJSON_AddArrayToObject(s, "lines");
      for (int k = 0; k < 12; ++k) cJSON_AddItemToArray(lines, cJSON_CreateString("l"));
      auto* trend = cJSON_AddArrayToObject(s, "trend");
      for (int k = 0; k < 10; ++k) cJSON_AddItemToArray(trend, cJSON_CreateNumber(k));
      cJSON_AddItemToArray(sections, s);
    }
    auto* alerts = cJSON_AddArrayToObject(big.get(), "alerts");
    for (int i = 0; i < 25; ++i) {
      auto* a = cJSON_CreateObject();
      cJSON_AddStringToObject(a, "key", "k");
      cJSON_AddStringToObject(a, "section", "tasks");
      cJSON_AddStringToObject(a, "level", "warn");
      cJSON_AddStringToObject(a, "title", "\xe4\xbb\xbb\xe5\x8a\xa1\xe5\xa4\xb1\xe8\xb4\xa5");
      cJSON_AddNumberToObject(a, "at", 1);
      cJSON_AddItemToArray(alerts, a);
    }
    display::Monitor out;
    assert(monitor(big.get(), out) && out.sections.size() == 5 && out.alerts.size() == 20);
    assert(out.sections[0].lines.size() == 8 && out.sections[0].trend.size() == 7 && out.sections[0].trend[0] == 3 && out.sections[0].trend[6] == 9);
    assert(out.sections[0].summary.size() == 160);
  }
  // A clipped multi-byte title is cut on a character boundary.
  assert(clip(std::string("\xe4\xbb\xbb\xe5\x8a\xa1"), 4) == "\xe4\xbb\xbb");
  assert(!parse("{} trailing"));
  assert(valid_wifi(parse(R"({"ssid":"wifi","password":"12345678"})").get()));
  assert(!valid_wifi(parse(R"({"ssid":"wifi","password":"short"})").get()));
  assert(!valid_wifi(parse(R"({"ssid":"wifi"})").get()));
  assert(valid_grant(parse(R"({"client_id":"device","refresh_token":"token"})").get()));
  assert(!valid_grant(parse(R"({"client_id":"device","refresh_token":""})").get()));
  assert(utf8("家里-5G") && !utf8("\xff") && !utf8("\xe5\xae") && !utf8("\xc0\x80") && !utf8("\xed\xa0\x80"));
  {
    auto list = parse(network_list(7, {{"家里", -40, true}, {"", -45, false}, {"家里", -60, true},
                                      {"\xff", -50, false}, {"Cafe", -70, false}}));
    const auto* nets = field(list.get(), "networks");
    assert(list && cJSON_GetArraySize(nets) == 2 && field(list.get(), "scan")->valueint == 7);
    assert(text(cJSON_GetArrayItem(nets, 0), "ssid") == "家里" && field(cJSON_GetArrayItem(nets, 0), "rssi")->valueint == -40);
    assert(cJSON_IsFalse(field(cJSON_GetArrayItem(nets, 1), "secure")));
    std::vector<Network> many;
    for (int i = 0; i < 20; ++i) many.push_back({std::string(32, char('a' + i)), -30 - i, true});
    const auto full = network_list(1, many);
    auto bounded = parse(full);
    assert(full.size() <= 512 && bounded && cJSON_GetArraySize(field(bounded.get(), "networks")) == 7);  // worst case: 32-byte names
  }
  std::ifstream fixture(std::filesystem::path(__FILE__).parent_path() / "desk_pull_response.sse");
  assert(fixture.good());
  const std::string actual((std::istreambuf_iterator<char>(fixture)), {});
  auto actual_response = parse_http(actual, "text/event-stream");
  assert(actual_response);
  const auto* content = field(field(actual_response.get(), "result"), "structuredContent");
  assert(cJSON_GetArraySize(field(content, "commands")) == 0);  // older server also sent `display`; firmware ignores it
  // Actual SDK response for 20 legal cards: six-byte escapes occur in both content shapes.
  std::ifstream maximum_fixture(std::filesystem::path(__FILE__).parent_path() / "desk_pull_max_response.sse");
  assert(maximum_fixture.good());
  const std::string maximum((std::istreambuf_iterator<char>(maximum_fixture)), {});
  assert(maximum.size() > 128 * 1024);
  auto maximum_response = parse_http(maximum, "text/event-stream");
  assert(maximum_response);
  const auto* commands = field(field(field(maximum_response.get(), "result"), "structuredContent"), "commands");
  assert(cJSON_GetArraySize(commands) == 20);
  for (int i = 0; i < 20; ++i) {
    const auto* command = cJSON_GetArrayItem(commands, i);
    assert(text(command, "title") == "T");
    assert(text(command, "body") == std::string(508, '\x01'));
  }
  const auto* first_content = cJSON_GetArrayItem(field(field(maximum_response.get(), "result"), "content"), 0);
  auto text_content = parse(text(first_content, "text"));
  assert(cJSON_GetArraySize(field(text_content.get(), "commands")) == 20);
  // Official Go MCP SDK streamable_test.go shape, including unrelated SSE events.
  const std::string sse = "event: ping\ndata: ping\n\nevent: message\nid: 1\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\nevent: keepalive\ndata: keepalive\n\n";
  assert(parse_http(sse, "text/event-stream"));
  assert(parse_http("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}", "application/json; charset=utf-8"));
  assert(parse_http("data: {\"jsonrpc\":\"2.0\",\"id\":1,\r\ndata: \"result\":{}}\r\n\r\n", "text/event-stream; charset=utf-8"));
  assert(!parse_http("data: bad\n\n", "text/event-stream"));
  assert(parse_http(std::string(192 * 1024 - 2, ' ') + "{}", "application/json"));
  assert(!parse_http(std::string(192 * 1024 + 1, 'x'), "application/json"));
  std::cout << "display JSON boundary tests passed\n";
}
