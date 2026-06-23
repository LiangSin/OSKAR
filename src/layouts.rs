use crate::hid::KeyType;

#[derive(Clone, Copy)]
pub struct KeyCombo {
    pub modifier: u8,
    pub keycode: usbd_hid::descriptor::KeyboardUsage,
}

pub struct KeyLayout {
    pub encoder_left: KeyType,
    pub encoder_right: KeyType,
    pub encoder_button: KeyType,
    pub key1: KeyType,
    pub key2: KeyType,
    pub key3: KeyType,
}
