//! Rectangles in physical pixels.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

impl Rect {
    pub fn new(x: i32, y: i32, width: u32, height: u32) -> Self {
        Self { x, y, width, height }
    }

    pub fn right(&self) -> i32 {
        self.x + self.width as i32
    }

    pub fn bottom(&self) -> i32 {
        self.y + self.height as i32
    }

    pub fn contains(&self, x: i32, y: i32) -> bool {
        x >= self.x && x < self.right() && y >= self.y && y < self.bottom()
    }

    /// The overlap, if there is any.
    pub fn intersection(&self, other: &Rect) -> Option<Rect> {
        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        let right = self.right().min(other.right());
        let bottom = self.bottom().min(other.bottom());
        (right > x && bottom > y).then(|| Rect::new(x, y, (right - x) as u32, (bottom - y) as u32))
    }

    pub fn offset(&self, dx: i32, dy: i32) -> Rect {
        Rect::new(self.x + dx, self.y + dy, self.width, self.height)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn intersects() {
        let a = Rect::new(0, 0, 100, 100);
        assert_eq!(a.intersection(&Rect::new(50, -10, 100, 30)), Some(Rect::new(50, 0, 50, 20)));
        assert_eq!(a.intersection(&Rect::new(100, 0, 10, 10)), None);
    }

    #[test]
    fn handles_displays_left_of_the_primary() {
        let left = Rect::new(-1920, 0, 1920, 1080);
        assert!(left.contains(-1, 10));
        assert!(!left.contains(0, 10));
        assert_eq!(Rect::new(-100, 10, 200, 20).intersection(&left), Some(Rect::new(-100, 10, 100, 20)));
    }
}
