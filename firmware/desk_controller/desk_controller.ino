// Standing desk height controller
// Arduino Nano + HC-SR04 ultrasonic sensor + 2x 5V relay modules wired
// across the desk hand-controller's UP and DOWN buttons.
//
// Talk to it over USB serial at 115200 baud, one command per line.
// Send "help" for the command list. All pins and calibration values are
// changeable at runtime with "set ..." and persisted with "save", so the
// wiring can be identified without recompiling.

#include <EEPROM.h>

// ---------- configuration (defaults; EEPROM overrides) ----------
struct Config {
  uint16_t magic;
  uint8_t  version;
  uint8_t  trigPin;
  uint8_t  echoPin;
  uint8_t  upPin;
  uint8_t  downPin;
  uint8_t  activeLow;      // 1 if relay module is "low level trigger"
  float    offsetCm;       // height = measured distance + offset
  float    sitCm;
  float    standCm;
  float    toleranceCm;    // consider arrived when |height - target| <= tol
  float    earlyUpCm;      // stop this far before target when going up (coasting)
  float    earlyDownCm;    // stop this far before target when going down
  uint16_t maxMoveMs;      // safety: longest a relay may stay engaged
  uint8_t  crc;
};

static const uint16_t CFG_MAGIC   = 0xDE5C;
static const uint8_t  CFG_VERSION = 1;

Config cfg;

void setDefaults() {
  cfg.magic       = CFG_MAGIC;
  cfg.version     = CFG_VERSION;
  cfg.trigPin     = 3;
  cfg.echoPin     = 2;
  cfg.upPin       = 4;
  cfg.downPin     = 5;
  cfg.activeLow   = 0;
  cfg.offsetCm    = 0.0f;
  cfg.sitCm       = 72.0f;
  cfg.standCm     = 110.0f;
  cfg.toleranceCm = 1.0f;
  cfg.earlyUpCm   = 0.3f;
  cfg.earlyDownCm = 0.8f;
  cfg.maxMoveMs   = 25000;
}

uint8_t cfgCrc(const Config &c) {
  const uint8_t *p = (const uint8_t *)&c;
  uint8_t x = 0x5A;
  for (size_t i = 0; i < sizeof(Config) - 1; i++) x ^= p[i] + (uint8_t)i;
  return x;
}

bool loadConfig() {
  Config tmp;
  EEPROM.get(0, tmp);
  if (tmp.magic != CFG_MAGIC || tmp.version != CFG_VERSION || tmp.crc != cfgCrc(tmp)) return false;
  cfg = tmp;
  return true;
}

void saveConfig() {
  cfg.crc = cfgCrc(cfg);
  EEPROM.put(0, cfg);
}

// ---------- relays ----------
enum Dir { NONE = 0, UP = 1, DOWN = 2 };
Dir moving = NONE;
unsigned long moveStartMs = 0;

void relayWrite(uint8_t pin, bool on) {
  bool level = on ? !cfg.activeLow : cfg.activeLow;
  digitalWrite(pin, level ? HIGH : LOW);
}

void relaysOff() {
  relayWrite(cfg.upPin, false);
  relayWrite(cfg.downPin, false);
}

void applyPins() {
  // Put every candidate pin back to input first, then configure the ones in use.
  for (uint8_t p = 2; p <= 12; p++) pinMode(p, INPUT);
  pinMode(cfg.trigPin, OUTPUT);
  digitalWrite(cfg.trigPin, LOW);
  pinMode(cfg.echoPin, INPUT);
  // Drive the inactive level BEFORE switching to output so the relay never blips.
  relayWrite(cfg.upPin, false);
  relayWrite(cfg.downPin, false);
  pinMode(cfg.upPin, OUTPUT);
  pinMode(cfg.downPin, OUTPUT);
  relayWrite(cfg.upPin, false);
  relayWrite(cfg.downPin, false);
}

void startMove(uint8_t d) {
  relaysOff();
  delay(20);  // make sure both are released before engaging one (interlock)
  if (d == UP)   relayWrite(cfg.upPin, true);
  if (d == DOWN) relayWrite(cfg.downPin, true);
  moving = (Dir)d;
  moveStartMs = millis();
}

void stopMove() {
  relaysOff();
  moving = NONE;
}

// ---------- ultrasonic sensor ----------
float readDistanceOnce(uint8_t trig, uint8_t echo) {
  digitalWrite(trig, LOW);
  delayMicroseconds(4);
  digitalWrite(trig, HIGH);
  delayMicroseconds(10);
  digitalWrite(trig, LOW);
  unsigned long us = pulseIn(echo, HIGH, 30000UL);  // ~5 m max
  if (us == 0) return -1.0f;
  return us / 58.0f;  // cm
}

float readDistanceOnce() { return readDistanceOnce(cfg.trigPin, cfg.echoPin); }

// Median of 5 valid readings. Returns -1 if fewer than 3 were valid.
float readDistance() {
  float v[5];
  uint8_t n = 0;
  for (uint8_t i = 0; i < 5; i++) {
    float d = readDistanceOnce();
    if (d > 2.0f && d < 450.0f) v[n++] = d;
    delay(12);
  }
  if (n < 3) return -1.0f;
  // insertion sort
  for (uint8_t i = 1; i < n; i++) {
    float k = v[i]; int8_t j = i - 1;
    while (j >= 0 && v[j] > k) { v[j + 1] = v[j]; j--; }
    v[j + 1] = k;
  }
  return v[n / 2];
}

float readHeight() {
  float d = readDistance();
  return d < 0 ? -1.0f : d + cfg.offsetCm;
}

// ---------- motion control ----------
bool  haveTarget = false;
float targetCm = 0;
uint8_t badReads = 0;
uint8_t retries = 0;
unsigned long settleUntilMs = 0;
float lastHeight = -1;

void beginGoto(float t) {
  if (t < 40 || t < cfg.offsetCm + 5 || t > 200) { Serial.println(F("ERR target out of range")); return; }
  targetCm = t;
  haveTarget = true;
  retries = 0;
  badReads = 0;
  settleUntilMs = 0;
  Serial.print(F("OK goto ")); Serial.println(t, 1);
}

void abortMove(const __FlashStringHelper *why) {
  stopMove();
  haveTarget = false;
  Serial.print(F("STOP ")); Serial.println(why);
}

void controlTick() {
  float h = readHeight();
  lastHeight = h;

  if (moving != NONE) {
    if (millis() - moveStartMs > cfg.maxMoveMs) { abortMove(F("timeout")); return; }
    if (h < 0) {
      if (++badReads >= 5) { abortMove(F("sensor lost")); return; }
      return;
    }
    badReads = 0;
    Serial.print(F("H ")); Serial.println(h, 1);
    float earlyUp = retries > 1 ? 0.0f : cfg.earlyUpCm;      // first move coasts; corrections don't
    float earlyDown = retries > 1 ? 0.0f : cfg.earlyDownCm;
    if (moving == UP && h >= targetCm - earlyUp) {
      stopMove(); settleUntilMs = millis() + 1200;
    } else if (moving == DOWN && h <= targetCm + earlyDown) {
      stopMove(); settleUntilMs = millis() + 1200;
    }
    return;
  }

  if (!haveTarget) return;
  if (millis() < settleUntilMs) return;  // let the desk coast to a stop
  if (h < 0) {
    if (++badReads >= 5) abortMove(F("no sensor reading"));
    return;
  }
  badReads = 0;

  float err = targetCm - h;
  if (fabs(err) <= cfg.toleranceCm) {
    haveTarget = false;
    Serial.print(F("DONE ")); Serial.println(h, 1);
    return;
  }
  if (retries >= 3) {
    haveTarget = false;
    Serial.print(F("DONE ")); Serial.print(h, 1); Serial.println(F(" (gave up within retries)"));
    return;
  }
  retries++;
  startMove(err > 0 ? UP : DOWN);
}

// ---------- serial command handling ----------
char line[64];
uint8_t lineLen = 0;

void printStatus() {
  Serial.print(F("STATUS height=")); Serial.print(lastHeight, 1);
  Serial.print(F(" moving=")); Serial.print(moving == UP ? "up" : moving == DOWN ? "down" : "no");
  Serial.print(F(" target=")); if (haveTarget) Serial.print(targetCm, 1); else Serial.print(F("none"));
  Serial.print(F(" sit=")); Serial.print(cfg.sitCm, 1);
  Serial.print(F(" stand=")); Serial.println(cfg.standCm, 1);
}

void printConfig() {
  Serial.print(F("CFG trig=")); Serial.print(cfg.trigPin);
  Serial.print(F(" echo=")); Serial.print(cfg.echoPin);
  Serial.print(F(" up=")); Serial.print(cfg.upPin);
  Serial.print(F(" down=")); Serial.print(cfg.downPin);
  Serial.print(F(" activelow=")); Serial.print(cfg.activeLow);
  Serial.print(F(" offset=")); Serial.print(cfg.offsetCm, 1);
  Serial.print(F(" sit=")); Serial.print(cfg.sitCm, 1);
  Serial.print(F(" stand=")); Serial.print(cfg.standCm, 1);
  Serial.print(F(" tol=")); Serial.print(cfg.toleranceCm, 1);
  Serial.print(F(" earlyup=")); Serial.print(cfg.earlyUpCm, 1);
  Serial.print(F(" earlydown=")); Serial.print(cfg.earlyDownCm, 1);
  Serial.print(F(" maxmove=")); Serial.println(cfg.maxMoveMs);
}

void printHelp() {
  Serial.println(F("Commands:"));
  Serial.println(F("  h | height          read height (cm)"));
  Serial.println(F("  status | cfg        show state / configuration"));
  Serial.println(F("  sit | stand         go to preset"));
  Serial.println(F("  go <cm>             go to height"));
  Serial.println(F("  stop                release relays, cancel target"));
  Serial.println(F("  up [ms] | down [ms] pulse a relay (default 500, max 3000)"));
  Serial.println(F("  pulse <pin> [ms]    pulse any pin 2-12 (to find relay wiring)"));
  Serial.println(F("  probe               auto-detect trig/echo order"));
  Serial.println(F("  scan                find the sensor on any pin pair"));
  Serial.println(F("  set <key> <val>     keys: trig echo up down activelow offset sit stand tol earlyup earlydown maxmove"));
  Serial.println(F("  save | load | defaults"));
}

bool pinOk(long p) { return p >= 2 && p <= 12; }

void doPulse(uint8_t pin, unsigned long ms) {
  if (ms > 3000) ms = 3000;
  stopMove(); haveTarget = false;
  relayWrite(pin, false);
  pinMode(pin, OUTPUT);
  relayWrite(pin, true);
  delay(ms);
  relayWrite(pin, false);
  if (pin != cfg.upPin && pin != cfg.downPin) pinMode(pin, INPUT);
  Serial.print(F("OK pulsed pin ")); Serial.print(pin); Serial.print(F(" for ")); Serial.print(ms); Serial.println(F(" ms"));
}

void doProbe() {
  uint8_t a = cfg.trigPin, b = cfg.echoPin;
  for (uint8_t attempt = 0; attempt < 2; attempt++) {
    uint8_t t = attempt == 0 ? a : b;
    uint8_t e = attempt == 0 ? b : a;
    pinMode(t, OUTPUT); digitalWrite(t, LOW); pinMode(e, INPUT);
    uint8_t good = 0;
    for (uint8_t i = 0; i < 5; i++) { float d = readDistanceOnce(t, e); if (d > 2 && d < 450) good++; delay(30); }
    if (good >= 3) {
      cfg.trigPin = t; cfg.echoPin = e; applyPins();
      Serial.print(F("OK sensor found: trig=")); Serial.print(t); Serial.print(F(" echo=")); Serial.println(e);
      return;
    }
  }
  applyPins();
  Serial.println(F("ERR no sensor response on either pin order (check wiring / try set trig, set echo)"));
}

float scanPair(uint8_t t, uint8_t e) {
  pinMode(e, INPUT);
  pinMode(t, OUTPUT);
  digitalWrite(t, LOW);
  delayMicroseconds(4);
  digitalWrite(t, HIGH);
  delayMicroseconds(10);
  digitalWrite(t, LOW);
  pinMode(t, INPUT);
  unsigned long us = pulseIn(e, HIGH, 25000UL);
  return us == 0 ? -1.0f : us / 58.0f;
}

void doScan() {
  Serial.println(F("SCAN trying every trig/echo pair on D2-D12..."));
  uint8_t hits = 0, bt = 0, be = 0;
  for (uint8_t p = 2; p <= 12; p++) pinMode(p, INPUT);
  for (uint8_t t = 2; t <= 12; t++) {
    for (uint8_t e = 2; e <= 12; e++) {
      if (t == e) continue;
      uint8_t good = 0; float sum = 0;
      for (uint8_t i = 0; i < 3; i++) { float d = scanPair(t, e); if (d > 2 && d < 450) { good++; sum += d; } delay(15); }
      if (good >= 2) {
        hits++; bt = t; be = e;
        Serial.print(F("SCAN hit trig=")); Serial.print(t); Serial.print(F(" echo=")); Serial.print(e);
        Serial.print(F(" dist=")); Serial.println(sum / good, 1);
      }
    }
  }
  if (hits == 1) {
    cfg.trigPin = bt; cfg.echoPin = be;
    Serial.print(F("OK sensor set to trig=")); Serial.print(bt); Serial.print(F(" echo=")); Serial.print(be); Serial.println(F(" (use 'save' to persist)"));
  } else if (hits == 0) {
    Serial.println(F("ERR scan found no sensor"));
  } else {
    Serial.println(F("ERR scan found several candidates; pick one with set trig / set echo"));
  }
  applyPins();
}

void setKey(const char *key, const char *val) {
  float f = atof(val);
  long  l = atol(val);
  if      (!strcmp(key, "trig"))      { if (!pinOk(l)) goto bad; cfg.trigPin = l; applyPins(); }
  else if (!strcmp(key, "echo"))      { if (!pinOk(l)) goto bad; cfg.echoPin = l; applyPins(); }
  else if (!strcmp(key, "up"))        { if (!pinOk(l)) goto bad; cfg.upPin = l; applyPins(); }
  else if (!strcmp(key, "down"))      { if (!pinOk(l)) goto bad; cfg.downPin = l; applyPins(); }
  else if (!strcmp(key, "activelow")) { cfg.activeLow = l ? 1 : 0; applyPins(); }
  else if (!strcmp(key, "offset"))    cfg.offsetCm = f;
  else if (!strcmp(key, "sit"))       cfg.sitCm = f;
  else if (!strcmp(key, "stand"))     cfg.standCm = f;
  else if (!strcmp(key, "tol"))       cfg.toleranceCm = f < 0.3f ? 0.3f : f;
  else if (!strcmp(key, "earlyup"))   cfg.earlyUpCm = f;
  else if (!strcmp(key, "earlydown")) cfg.earlyDownCm = f;
  else if (!strcmp(key, "maxmove"))   cfg.maxMoveMs = l < 1000 ? 1000 : (l > 60000 ? 60000 : l);
  else { Serial.println(F("ERR unknown key")); return; }
  Serial.println(F("OK (use 'save' to persist)"));
  return;
bad:
  Serial.println(F("ERR pin must be 2-12"));
}

void handleLine(char *s) {
  // lower-case, split on spaces
  for (char *p = s; *p; p++) *p = tolower(*p);
  char *cmd = strtok(s, " \t");
  if (!cmd) return;
  char *a1 = strtok(NULL, " \t");
  char *a2 = strtok(NULL, " \t");

  if (!strcmp(cmd, "help") || !strcmp(cmd, "?")) printHelp();
  else if (!strcmp(cmd, "h") || !strcmp(cmd, "height")) { float h = readHeight(); lastHeight = h; Serial.print(F("H ")); Serial.println(h, 1); }
  else if (!strcmp(cmd, "status")) printStatus();
  else if (!strcmp(cmd, "cfg")) printConfig();
  else if (!strcmp(cmd, "sit")) beginGoto(cfg.sitCm);
  else if (!strcmp(cmd, "stand")) beginGoto(cfg.standCm);
  else if (!strcmp(cmd, "go") && a1) beginGoto(atof(a1));
  else if (!strcmp(cmd, "stop")) { stopMove(); haveTarget = false; Serial.println(F("OK stopped")); }
  else if (!strcmp(cmd, "up")) doPulse(cfg.upPin, a1 ? atol(a1) : 500);
  else if (!strcmp(cmd, "down")) doPulse(cfg.downPin, a1 ? atol(a1) : 500);
  else if (!strcmp(cmd, "pulse") && a1) { long p = atol(a1); if (!pinOk(p)) Serial.println(F("ERR pin must be 2-12")); else doPulse(p, a2 ? atol(a2) : 500); }
  else if (!strcmp(cmd, "probe")) doProbe();
  else if (!strcmp(cmd, "scan")) doScan();
  else if (!strcmp(cmd, "set") && a1 && a2) setKey(a1, a2);
  else if (!strcmp(cmd, "save")) { saveConfig(); Serial.println(F("OK saved")); }
  else if (!strcmp(cmd, "load")) { if (loadConfig()) { applyPins(); Serial.println(F("OK loaded")); } else Serial.println(F("ERR nothing valid in EEPROM")); }
  else if (!strcmp(cmd, "defaults")) { setDefaults(); applyPins(); Serial.println(F("OK defaults (use 'save' to persist)")); }
  else Serial.println(F("ERR unknown command (try 'help')"));
}

void pollSerial() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\r') continue;
    if (c == '\n') {
      line[lineLen] = 0;
      if (lineLen) handleLine(line);
      lineLen = 0;
    } else if (lineLen < sizeof(line) - 1) {
      line[lineLen++] = c;
    }
  }
}

// ---------- main ----------
void setup() {
  setDefaults();
  bool fromEeprom = loadConfig();
  applyPins();
  Serial.begin(115200);
  Serial.print(F("READY desk-controller v1 config="));
  Serial.println(fromEeprom ? F("eeprom") : F("defaults"));
  printConfig();
}

unsigned long lastTickMs = 0;

void loop() {
  pollSerial();
  unsigned long now = millis();
  unsigned long period = moving != NONE ? 80 : 250;
  if (now - lastTickMs >= period) {
    lastTickMs = now;
    if (moving != NONE || haveTarget) controlTick();
  }
}
