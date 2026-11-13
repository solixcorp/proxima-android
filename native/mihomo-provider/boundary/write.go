package boundary

import (
	"crypto/rand"
	"errors"
	"os"
	"path/filepath"
)

// WriteFile publishes a parsed provider cache by atomic replacement. Opening
// the parent pins it for creation, rename, and cleanup despite concurrent
// directory renames. A final symlink is replaced, never followed by the write.
func WriteFile(path string, contents []byte) (err error) {
	root, name, err := resolve(path)
	if err != nil {
		return err
	}
	dir := filepath.Dir(name)
	if err = root.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	parent, err := root.OpenRoot(dir)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, parent.Close()) }()
	temp := ".provider-" + rand.Text()
	f, err := parent.OpenFile(temp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	published := false
	defer func() {
		if !published {
			err = errors.Join(err, parent.Remove(temp))
		}
	}()
	_, writeErr := f.Write(contents)
	syncErr := f.Sync()
	closeErr := f.Close()
	if err = errors.Join(writeErr, syncErr, closeErr); err != nil {
		return err
	}
	if err = parent.Rename(temp, filepath.Base(name)); err != nil {
		return err
	}
	published = true
	return nil
}
