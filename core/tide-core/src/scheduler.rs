//! Download hours, slow-mode schedule and per-task start times. Pure functions over an injected
//! clock (unix seconds + the local UTC offset the Swift side reports), so they're fully testable.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Window {
    /// Minutes after local midnight. `end <= start` crosses midnight; `start == end` = all day.
    pub start: u32,
    pub end: u32,
    /// Bit (weekday-1): 1 = Sunday … 7 = Saturday, Calendar numbering.
    pub weekdays: u8,
}

impl Window {
    pub fn every_day(start: u32, end: u32) -> Self {
        Window { start, end, weekdays: 0x7f }
    }
    fn on(&self, weekday: u32) -> bool {
        (1..=7).contains(&weekday) && self.weekdays & (1 << (weekday - 1)) != 0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Clock {
    pub now: i64,
    pub utc_offset: i64, // seconds east of UTC
}

impl Clock {
    fn local(&self, t: i64) -> i64 { t + self.utc_offset }
    /// (weekday 1=Sun…7=Sat, minute of day) at unix time `t`.
    pub fn parts(&self, t: i64) -> (u32, u32) {
        let l = self.local(t);
        let days = l.div_euclid(86_400);
        let minute = (l.rem_euclid(86_400) / 60) as u32;
        // 1970-01-01 was a Thursday (weekday 5).
        let weekday = ((days + 4).rem_euclid(7) + 1) as u32;
        (weekday, minute)
    }
    /// Unix time of local midnight starting the day that contains `t`.
    fn midnight(&self, t: i64) -> i64 {
        let l = self.local(t);
        l - l.rem_euclid(86_400) - self.utc_offset
    }
}

fn prev_day(w: u32) -> u32 { if w == 1 { 7 } else { w - 1 } }

pub fn in_window(w: &Window, clock: &Clock, t: i64) -> bool {
    let (wd, m) = clock.parts(t);
    if w.start == w.end {
        return w.on(wd);
    }
    if w.start < w.end {
        w.on(wd) && m >= w.start && m < w.end
    } else {
        (w.on(wd) && m >= w.start) || (w.on(prev_day(wd)) && m < w.end)
    }
}

/// Next time strictly after `clock.now` at which the window opens.
pub fn next_start(w: &Window, clock: &Clock) -> Option<i64> {
    if w.weekdays & 0x7f == 0 { return None; }
    let base = clock.midnight(clock.now);
    for d in 0..9 {
        let day = base + d * 86_400;
        let cand = day + w.start as i64 * 60;
        let (wd, _) = clock.parts(day + 3_600 * 12);
        if cand > clock.now && w.on(wd) && !in_window(w, clock, cand - 60) {
            return Some(cand);
        }
    }
    None
}

/// When the window that is open at `clock.now` closes.
pub fn current_end(w: &Window, clock: &Clock) -> Option<i64> {
    if !in_window(w, clock, clock.now) { return None; }
    if w.start == w.end {
        // All-day windows end at the first midnight whose next day isn't selected.
        let mut t = clock.midnight(clock.now) + 86_400;
        for _ in 0..8 {
            if !in_window(w, clock, t) { return Some(t); }
            t += 86_400;
        }
        return None;
    }
    let (_, m) = clock.parts(clock.now);
    let today = clock.midnight(clock.now);
    let end = if w.start < w.end || m < w.end { today + w.end as i64 * 60 } else { today + 86_400 + w.end as i64 * 60 };
    Some(end)
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Hours {
    AnyTime,
    Inside { ends_at: i64 },
    Outside { starts_at: i64 },
}

pub fn hours_status(enabled: bool, w: &Window, clock: &Clock) -> Hours {
    if !enabled { return Hours::AnyTime; }
    if in_window(w, clock, clock.now) {
        Hours::Inside { ends_at: current_end(w, clock).unwrap_or(i64::MAX) }
    } else {
        match next_start(w, clock) {
            Some(s) => Hours::Outside { starts_at: s },
            None => Hours::Outside { starts_at: i64::MAX },
        }
    }
}

/// Per-task decision.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Hold {
    Run,
    /// Waiting for the window or the task's own start time.
    Scheduled { starts_at: i64 },
}

/// `start_at`: explicit per-task time (overrides hours once it passes).
/// `override_until`: "Start Now" — run regardless of hours until this time.
pub fn task_hold(hours: Hours, start_at: Option<i64>, override_until: Option<i64>, now: i64) -> Hold {
    if let Some(t) = start_at {
        return if now < t { Hold::Scheduled { starts_at: t } } else { Hold::Run };
    }
    if override_until.is_some_and(|u| now < u) {
        return Hold::Run;
    }
    match hours {
        Hours::Outside { starts_at } => Hold::Scheduled { starts_at },
        _ => Hold::Run,
    }
}

/// Slow mode: a manual toggle wins until the schedule's own value changes (its next boundary).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub struct SlowModeState {
    pub manual: Option<bool>,
    /// What the schedule said when the manual toggle was made.
    pub schedule_at_toggle: bool,
}

pub fn slow_mode_effective(state: &mut SlowModeState, scheduled_enabled: bool, w: &Window, clock: &Clock) -> bool {
    if !scheduled_enabled {
        return state.manual.unwrap_or(false);
    }
    let sched = in_window(w, clock, clock.now);
    match state.manual {
        Some(v) if sched == state.schedule_at_toggle => v,
        Some(_) => {
            state.manual = None;
            sched
        }
        None => sched,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 2026-11-22 is a Sunday. Use UTC+2 (Beirut-like) local time.
    const OFF: i64 = 2 * 3600;
    fn at(day_offset: i64, h: i64, m: i64) -> Clock {
        // 2026-11-22 00:00 local = 2026-11-21 22:00 UTC.
        let sunday_midnight_local = 1_795_305_600 - OFF; // 2026-11-22T00:00:00Z minus offset
        Clock { now: sunday_midnight_local + day_offset * 86_400 + h * 3600 + m * 60, utc_offset: OFF }
    }

    #[test]
    fn parts_are_local() {
        let c = at(0, 1, 30);
        assert_eq!(c.parts(c.now), (1, 90)); // Sunday 01:30
        let c = at(6, 23, 59);
        assert_eq!(c.parts(c.now), (7, 23 * 60 + 59)); // Saturday
    }

    #[test]
    fn simple_window() {
        let w = Window::every_day(60, 480); // 01:00–08:00
        assert!(in_window(&w, &at(0, 1, 0), at(0, 1, 0).now));
        assert!(!in_window(&w, &at(0, 8, 0), at(0, 8, 0).now));
        let c = at(0, 15, 0);
        assert_eq!(next_start(&w, &c), Some(at(1, 1, 0).now));
        let c = at(0, 0, 30);
        assert_eq!(next_start(&w, &c), Some(at(0, 1, 0).now));
        assert_eq!(current_end(&w, &at(0, 3, 0)), Some(at(0, 8, 0).now));
    }

    #[test]
    fn window_past_midnight() {
        let w = Window::every_day(22 * 60, 6 * 60);
        assert!(in_window(&w, &at(0, 23, 0), at(0, 23, 0).now));
        assert!(in_window(&w, &at(1, 2, 0), at(1, 2, 0).now));
        assert!(!in_window(&w, &at(1, 7, 0), at(1, 7, 0).now));
        assert_eq!(current_end(&w, &at(0, 23, 0)), Some(at(1, 6, 0).now));
        assert_eq!(current_end(&w, &at(1, 2, 0)), Some(at(1, 6, 0).now));
    }

    #[test]
    fn weekdays_respected() {
        // Weekends only (Sun=bit0, Sat=bit6), 10:00–12:00.
        let w = Window { start: 600, end: 720, weekdays: 0b100_0001 };
        assert!(in_window(&w, &at(0, 11, 0), at(0, 11, 0).now)); // Sunday
        assert!(!in_window(&w, &at(1, 11, 0), at(1, 11, 0).now)); // Monday
        assert_eq!(next_start(&w, &at(0, 13, 0)), Some(at(6, 10, 0).now)); // next Saturday
    }

    #[test]
    fn task_holds() {
        let w = Window::every_day(60, 480);
        let c = at(0, 15, 0);
        let h = hours_status(true, &w, &c);
        assert_eq!(task_hold(h, None, None, c.now), Hold::Scheduled { starts_at: at(1, 1, 0).now });
        assert_eq!(task_hold(h, None, Some(i64::MAX), c.now), Hold::Run);
        // Explicit time overrides hours once it passes.
        assert_eq!(task_hold(h, Some(c.now - 1), None, c.now), Hold::Run);
        assert_eq!(task_hold(h, Some(c.now + 60), None, c.now), Hold::Scheduled { starts_at: c.now + 60 });
        assert_eq!(task_hold(hours_status(false, &w, &c), None, None, c.now), Hold::Run);
    }

    #[test]
    fn slow_mode_manual_until_boundary() {
        let w = Window::every_day(18 * 60, 23 * 60);
        let mut s = SlowModeState { manual: Some(true), schedule_at_toggle: false };
        assert!(slow_mode_effective(&mut s, true, &w, &at(0, 12, 0)));
        // At 18:00 the schedule flips on: manual is dropped, schedule rules.
        assert!(slow_mode_effective(&mut s, true, &w, &at(0, 19, 0)));
        assert_eq!(s.manual, None);
        let mut off = SlowModeState { manual: Some(false), schedule_at_toggle: true };
        assert!(!slow_mode_effective(&mut off, true, &w, &at(0, 19, 0)));
        assert!(!slow_mode_effective(&mut off, true, &w, &at(0, 23, 30)));
        assert_eq!(off.manual, None);
    }
}
