//! GATT framing: every frame is `flags(1) ‖ seq(2, big-endian) ‖ data`; flags bit0 = first frame of a message, bit1 =
//! last; seq starts at 0 for each message (provd frame.go:8-49; 219-protocol.md). A violation is fatal: the caller
//! closes the connection (the node does the same).

pub const HEADER: usize = 3;
const FIRST: u8 = 0x01;
const LAST: u8 = 0x02;

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    FrameTooShort,
    FrameTooLong,
    NoStartFlag,
    UnexpectedStart,
    SeqJump { want: u16, got: u16 },
    MessageTooLong,
    SeqOverflow,
}

/// Splits `msg` into frames of at most `frame_limit` bytes (header included).
pub fn split(msg: &[u8], frame_limit: usize) -> Result<Vec<Vec<u8>>, Error> {
    if frame_limit <= HEADER {
        return Err(Error::FrameTooShort);
    }
    let per = frame_limit - HEADER;
    let chunks: Vec<&[u8]> = if msg.is_empty() { vec![&[][..]] } else { msg.chunks(per).collect() };
    if chunks.len() > u16::MAX as usize + 1 {
        return Err(Error::SeqOverflow);
    }
    let last = chunks.len() - 1;
    Ok(chunks
        .iter()
        .enumerate()
        .map(|(i, c)| {
            let mut flags = 0;
            if i == 0 {
                flags |= FIRST;
            }
            if i == last {
                flags |= LAST;
            }
            let mut f = Vec::with_capacity(HEADER + c.len());
            f.push(flags);
            f.extend((i as u16).to_be_bytes());
            f.extend(*c);
            f
        })
        .collect())
}

/// Reassembles one message at a time; `push` returns `Some(message)` when a frame with the last flag completes it.
pub struct Reassembler {
    frame_limit: usize,
    max_message: usize,
    cur: Option<(u16, Vec<u8>)>,
}

impl Reassembler {
    /// `frame_limit`: the largest frame accepted (header included); `max_message`: the largest reassembled message.
    pub fn new(frame_limit: usize, max_message: usize) -> Self {
        Reassembler { frame_limit, max_message, cur: None }
    }

    pub fn push(&mut self, frame: &[u8]) -> Result<Option<Vec<u8>>, Error> {
        if frame.len() < HEADER {
            return Err(Error::FrameTooShort);
        }
        if frame.len() > self.frame_limit {
            return Err(Error::FrameTooLong);
        }
        let flags = frame[0];
        let seq = u16::from_be_bytes([frame[1], frame[2]]);
        let data = &frame[HEADER..];
        let (mut want, mut buf) = match self.cur.take() {
            None if flags & FIRST == 0 => return Err(Error::NoStartFlag),
            None => (0u16, Vec::new()),
            Some(_) if flags & FIRST != 0 => return Err(Error::UnexpectedStart),
            Some(c) => c,
        };
        if seq != want {
            return Err(Error::SeqJump { want, got: seq });
        }
        if buf.len() + data.len() > self.max_message {
            return Err(Error::MessageTooLong);
        }
        buf.extend(data);
        if flags & LAST != 0 {
            return Ok(Some(buf));
        }
        want = want.checked_add(1).ok_or(Error::SeqOverflow)?;
        self.cur = Some((want, buf));
        Ok(None)
    }
}
