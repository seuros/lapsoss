#![allow(clippy::unwrap_used, reason = "test setup must fail immediately")]

use std::{
    os::unix::fs::DirBuilderExt,
    path::{Path, PathBuf},
};

pub struct Directory(pub PathBuf);

impl Directory {
    pub fn new() -> Self {
        let path =
            Path::new("/tmp").join(format!("lapsossd-{}", lapsoss::Event::message("", "").id));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .unwrap();
        Self(path)
    }
}

impl Drop for Directory {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).unwrap();
    }
}
