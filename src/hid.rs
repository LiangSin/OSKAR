use crate::layouts::{KeyCombo, KeyLayout};
use crate::{ButtonResources, EncoderResources};
use defmt::unreachable;
use defmt_rtt as _;
use embassy_executor::{InterruptExecutor, Spawner};
use embassy_futures::select::{Either, select, select_array};
use embassy_rp::gpio::{Input, Level, Pull};
use embassy_rp::interrupt;
use embassy_rp::interrupt::{InterruptExt, Priority};
use embassy_rp::peripherals::USB;
use embassy_rp::usb::Driver;
use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_sync::pubsub::PubSubChannel;
use embassy_time::{Duration, Timer};
use embassy_usb::class::hid::{HidReaderWriter, HidWriter};
use usbd_hid::descriptor::*;
type CustomHid = HidReaderWriter<'static, Driver<'static, USB>, 1, 8>;
type CustomHidWriter = HidWriter<'static, Driver<'static, USB>, 8>;
static KEY_EVENT_QUEUE: PubSubChannel<CriticalSectionRawMutex, KeyEvent, 8, 2, 2> =
    PubSubChannel::new();

pub const OSKAR_CUSTOM_HID_REPORT_DESCRIPTOR: &[u8] = &[
    0x06, 0x00, 0xff, // Usage Page (Vendor Defined 0xFF00)
    0x09, 0x01, // Usage (OSKAR Macro Keys)
    0xa1, 0x01, // Collection (Application)
    0x09, 0x10, // Usage (Macro Key Report)
    0x15, 0x00, // Logical Minimum (0)
    0x26, 0xff, 0x00, // Logical Maximum (255)
    0x75, 0x08, // Report Size (8)
    0x95, 0x02, // Report Count (2)
    0x81, 0x02, // Input (Data, Variable, Absolute)
    0xc0, // End Collection
];

#[derive(Clone, PartialEq)]
enum Key {
    EncoderLeft,
    EncoderRight,
    EncoderButton,
    Key1,
    Key2,
    Key3,
}

#[derive(Clone, PartialEq)]
enum Event {
    Pressed,
    Released,
}
#[derive(Clone)]
struct KeyEvent {
    key: Key,
    event: Event,
}

#[allow(dead_code)]
#[derive(Clone, Copy)]
pub enum KeyType {
    Media(MediaKey),
    Keycode(KeyboardUsage),
    Combo(KeyCombo),
    Toggle { first: KeyCombo, second: KeyCombo },
}

#[derive(Clone, Copy)]
pub enum OskarButton {
    Key1 = 1,
    Key2 = 2,
    Key3 = 3,
}

const MOD_LEFT_SHIFT: u8 = 0x02;
const MOD_LEFT_ALT: u8 = 0x04;
const MOD_LEFT_GUI: u8 = 0x08;
const WINDOW_SWITCH_TIMEOUT: Duration = Duration::from_secs(1);
const ENCODER_STEPS_PER_DETENT: i8 = 4;
const BUTTON_DEBOUNCE: Duration = Duration::from_millis(20);

const KEYLAYOUT: KeyLayout = KeyLayout {
    encoder_left: KeyType::Combo(KeyCombo {
        modifier: MOD_LEFT_ALT | MOD_LEFT_SHIFT,
        keycode: KeyboardUsage::KeyboardTab,
    }),
    encoder_right: KeyType::Combo(KeyCombo {
        modifier: MOD_LEFT_ALT,
        keycode: KeyboardUsage::KeyboardTab,
    }),
    encoder_button: KeyType::Toggle {
        first: KeyCombo {
            modifier: MOD_LEFT_GUI,
            keycode: KeyboardUsage::KeyboardUpArrow,
        },
        second: KeyCombo {
            modifier: MOD_LEFT_GUI,
            keycode: KeyboardUsage::KeyboardDownArrow,
        },
    },
    key1: OskarButton::Key1,
    key2: OskarButton::Key2,
    key3: OskarButton::Key3,
};

#[embassy_executor::task]
pub async fn hid_task(
    spawner: Spawner,
    mut keyboard_class: CustomHid,
    mut multimedia_class: CustomHid,
    mut oskar_class: CustomHidWriter,
    button_resources: ButtonResources,
    encoder_resources: EncoderResources,
) -> ! {
    interrupt::SWI_IRQ_0.set_priority(Priority::P2);
    let spawner_encoder: embassy_executor::SendSpawner =
        EXECUTOR_ENCODER.start(interrupt::SWI_IRQ_0);
    spawner_encoder
        .spawn(encoder_task(encoder_resources))
        .unwrap();

    spawner.spawn(button_task(button_resources)).unwrap();

    let mut sub = KEY_EVENT_QUEUE.subscriber().unwrap();
    let mut encoder_button_toggle = false;
    let mut window_switch_active = false;

    loop {
        let key_event: KeyEvent = if window_switch_active {
            match select(sub.next_message_pure(), Timer::after(WINDOW_SWITCH_TIMEOUT)).await {
                Either::First(key_event) => key_event,
                Either::Second(_) => {
                    keyboard_class = release_keyboard(keyboard_class).await;
                    window_switch_active = false;
                    continue;
                }
            }
        } else {
            sub.next_message_pure().await
        };

        if window_switch_active && key_event.cancels_window_switch() {
            window_switch_active = false;
        }

        match key_event.key {
            Key::EncoderLeft => {
                keyboard_class =
                    handle_window_switch_interaction(keyboard_class, KEYLAYOUT.encoder_left).await;
                window_switch_active = true;
            }
            Key::EncoderRight => {
                keyboard_class =
                    handle_window_switch_interaction(keyboard_class, KEYLAYOUT.encoder_right).await;
                window_switch_active = true;
            }
            Key::EncoderButton => {
                (keyboard_class, multimedia_class, encoder_button_toggle) =
                    handle_toggle_interaction(
                        keyboard_class,
                        multimedia_class,
                        KEYLAYOUT.encoder_button,
                        key_event.event,
                        encoder_button_toggle,
                    )
                    .await;
            }
            Key::Key1 => {
                oskar_class = send_oskar_button(oskar_class, KEYLAYOUT.key1, key_event.event).await;
            }
            Key::Key2 => {
                oskar_class = send_oskar_button(oskar_class, KEYLAYOUT.key2, key_event.event).await;
            }
            Key::Key3 => {
                oskar_class = send_oskar_button(oskar_class, KEYLAYOUT.key3, key_event.event).await;
            }
        }
    }
}

impl KeyEvent {
    fn cancels_window_switch(&self) -> bool {
        !matches!(self.key, Key::EncoderLeft | Key::EncoderRight)
    }
}

static EXECUTOR_ENCODER: InterruptExecutor = InterruptExecutor::new();

#[interrupt]
unsafe fn SWI_IRQ_0() {
    unsafe { EXECUTOR_ENCODER.on_interrupt() }
}

#[embassy_executor::task]
pub async fn encoder_task(r: EncoderResources) -> ! {
    let mut encoder_left: Input<'_> = Input::new(r.encoder_left, Pull::None);

    let mut encoder_right: Input<'_> = Input::new(r.encoder_right, Pull::None);

    let publisher = KEY_EVENT_QUEUE.publisher().unwrap();
    let mut last_state = encoder_state(&encoder_left, &encoder_right);
    let mut position: i8 = 0;

    loop {
        let (_, _) = select_array([
            encoder_left.wait_for_any_edge(),
            encoder_right.wait_for_any_edge(),
        ])
        .await;

        let state = encoder_state(&encoder_left, &encoder_right);
        let transition = (last_state << 2) | state;
        last_state = state;

        let Some(delta) = encoder_transition_delta(transition) else {
            position = 0;
            continue;
        };

        position += delta;

        if position >= ENCODER_STEPS_PER_DETENT {
            position = 0;
            publisher.publish_immediate(KeyEvent {
                key: Key::EncoderRight,
                event: Event::Pressed,
            });
        } else if position <= -ENCODER_STEPS_PER_DETENT {
            position = 0;
            publisher.publish_immediate(KeyEvent {
                key: Key::EncoderLeft,
                event: Event::Pressed,
            });
        }
    }
}

fn encoder_state(encoder_left: &Input<'_>, encoder_right: &Input<'_>) -> u8 {
    let left = match encoder_left.get_level() {
        Level::Low => 0,
        Level::High => 1,
    };
    let right = match encoder_right.get_level() {
        Level::Low => 0,
        Level::High => 1,
    };

    (left << 1) | right
}

fn encoder_transition_delta(transition: u8) -> Option<i8> {
    match transition {
        0b0001 | 0b0111 | 0b1110 | 0b1000 => Some(1),
        0b0010 | 0b1011 | 0b1101 | 0b0100 => Some(-1),
        0b0000 | 0b0101 | 0b1010 | 0b1111 => Some(0),
        _ => None,
    }
}

#[embassy_executor::task]
pub async fn button_task(r: ButtonResources) -> ! {
    let mut key1: Input<'_> = Input::new(r.key1, Pull::Up);
    key1.set_schmitt(true);

    let mut key2: Input<'_> = Input::new(r.key2, Pull::Up);
    key2.set_schmitt(true);

    let mut key3: Input<'_> = Input::new(r.key3, Pull::Up);
    key3.set_schmitt(true);

    let mut encoder_button: Input<'_> = Input::new(r.encoder_button, Pull::Up);
    encoder_button.set_schmitt(true);

    let publisher = KEY_EVENT_QUEUE.publisher().unwrap();
    let mut key1_pressed = key1.get_level() == Level::Low;
    let mut key2_pressed = key2.get_level() == Level::Low;
    let mut key3_pressed = key3.get_level() == Level::Low;
    let mut encoder_button_pressed = encoder_button.get_level() == Level::Low;

    loop {
        let (_, index) = select_array([
            key1.wait_for_any_edge(),
            key2.wait_for_any_edge(),
            key3.wait_for_any_edge(),
            encoder_button.wait_for_any_edge(),
        ])
        .await;

        Timer::after(BUTTON_DEBOUNCE).await;

        match index {
            0 => {
                let pressed = key1.get_level() == Level::Low;
                if pressed != key1_pressed {
                    key1_pressed = pressed;
                    publisher.publish_immediate(KeyEvent {
                        key: Key::Key1,
                        event: if pressed {
                            Event::Pressed
                        } else {
                            Event::Released
                        },
                    });
                }
            }
            1 => {
                let pressed = key2.get_level() == Level::Low;
                if pressed != key2_pressed {
                    key2_pressed = pressed;
                    publisher.publish_immediate(KeyEvent {
                        key: Key::Key2,
                        event: if pressed {
                            Event::Pressed
                        } else {
                            Event::Released
                        },
                    });
                }
            }
            2 => {
                let pressed = key3.get_level() == Level::Low;
                if pressed != key3_pressed {
                    key3_pressed = pressed;
                    publisher.publish_immediate(KeyEvent {
                        key: Key::Key3,
                        event: if pressed {
                            Event::Pressed
                        } else {
                            Event::Released
                        },
                    });
                }
            }
            3 => {
                let pressed = encoder_button.get_level() == Level::Low;
                if pressed != encoder_button_pressed {
                    encoder_button_pressed = pressed;
                    publisher.publish_immediate(KeyEvent {
                        key: Key::EncoderButton,
                        event: if pressed {
                            Event::Pressed
                        } else {
                            Event::Released
                        },
                    });
                }
            }
            _ => unreachable!(),
        };
    }
}

async fn handle_window_switch_interaction(keyboard_class: CustomHid, code: KeyType) -> CustomHid {
    match code {
        KeyType::Combo(combo) => send_combo_tap_keep_modifier(keyboard_class, combo).await,
        _ => keyboard_class,
    }
}

async fn handle_toggle_interaction(
    keyboard_class: CustomHid,
    media_class: CustomHid,
    code: KeyType,
    event: Event,
    toggle_state: bool,
) -> (CustomHid, CustomHid, bool) {
    match (code, event) {
        (KeyType::Toggle { first, second }, Event::Pressed) => {
            let combo = if toggle_state { second } else { first };
            let (keyboard_class, media_class) =
                send_combo_tap(keyboard_class, media_class, combo).await;
            (keyboard_class, media_class, !toggle_state)
        }
        (KeyType::Toggle { .. }, Event::Released) => (keyboard_class, media_class, toggle_state),
        (code, event) => {
            let (keyboard_class, media_class) =
                send_code(keyboard_class, media_class, code, event).await;
            (keyboard_class, media_class, toggle_state)
        }
    }
}

async fn send_combo_tap(
    mut keyboard_class: CustomHid,
    media_class: CustomHid,
    combo: KeyCombo,
) -> (CustomHid, CustomHid) {
    let mut report = KeyboardReport {
        keycodes: [combo.keycode as u8, 0, 0, 0, 0, 0],
        leds: 0,
        modifier: combo.modifier,
        reserved: 0,
    };

    if let Err(e) = keyboard_class.write_serialize(&report).await {
        log::error!("Failed to send HID key press: {:?}", e);
    }

    report.keycodes = [0, 0, 0, 0, 0, 0];
    report.modifier = 0;

    if let Err(e) = keyboard_class.write_serialize(&report).await {
        log::error!("Failed to send HID key release: {:?}", e);
    }

    (keyboard_class, media_class)
}

async fn send_combo_tap_keep_modifier(mut keyboard_class: CustomHid, combo: KeyCombo) -> CustomHid {
    let mut report = KeyboardReport {
        keycodes: [combo.keycode as u8, 0, 0, 0, 0, 0],
        leds: 0,
        modifier: combo.modifier,
        reserved: 0,
    };

    if let Err(e) = keyboard_class.write_serialize(&report).await {
        log::error!("Failed to send HID key press: {:?}", e);
    }

    report.keycodes = [0, 0, 0, 0, 0, 0];
    report.modifier = combo.modifier & !MOD_LEFT_SHIFT;

    if let Err(e) = keyboard_class.write_serialize(&report).await {
        log::error!("Failed to send HID key release: {:?}", e);
    }

    keyboard_class
}

async fn release_keyboard(mut keyboard_class: CustomHid) -> CustomHid {
    let report = KeyboardReport {
        keycodes: [0, 0, 0, 0, 0, 0],
        leds: 0,
        modifier: 0,
        reserved: 0,
    };

    if let Err(e) = keyboard_class.write_serialize(&report).await {
        log::error!("Failed to send HID key release: {:?}", e);
    }

    keyboard_class
}

async fn send_code(
    mut keyboard_class: CustomHid,
    mut media_class: CustomHid,
    code: KeyType,
    event: Event,
) -> (CustomHid, CustomHid) {
    match code {
        KeyType::Media(media_key) => {
            let code = match event {
                Event::Pressed => media_key as u16,
                Event::Released => 0x00 as u16,
            };

            let report = MediaKeyboardReport { usage_id: code };

            if let Err(e) = media_class.write_serialize(&report).await {
                log::error!("Failed to send HID key press: {:?}", e);
            }
        }
        KeyType::Keycode(keyboard_usage) => {
            let keycodes: [u8; 6] = if event == Event::Pressed {
                [keyboard_usage as u8, 0, 0, 0, 0, 0]
            } else {
                [0, 0, 0, 0, 0, 0]
            };

            let report = KeyboardReport {
                keycodes,
                leds: 0,
                modifier: 0,
                reserved: 0,
            };

            if let Err(e) = keyboard_class.write_serialize(&report).await {
                log::error!("Failed to send HID key press: {:?}", e);
            }
        }
        KeyType::Combo(combo) => {
            let (keycodes, modifier) = if event == Event::Pressed {
                ([combo.keycode as u8, 0, 0, 0, 0, 0], combo.modifier)
            } else {
                ([0, 0, 0, 0, 0, 0], 0)
            };

            let report = KeyboardReport {
                keycodes,
                leds: 0,
                modifier,
                reserved: 0,
            };

            if let Err(e) = keyboard_class.write_serialize(&report).await {
                log::error!("Failed to send HID key press: {:?}", e);
            }
        }
        KeyType::Toggle { .. } => {}
    };

    (keyboard_class, media_class)
}

async fn send_oskar_button(
    mut oskar_class: CustomHidWriter,
    button: OskarButton,
    event: Event,
) -> CustomHidWriter {
    let report = [
        button as u8,
        match event {
            Event::Pressed => 1,
            Event::Released => 0,
        },
    ];

    if let Err(e) = oskar_class.write(&report).await {
        log::error!("Failed to send OSKAR custom HID report: {:?}", e);
    }

    oskar_class
}
