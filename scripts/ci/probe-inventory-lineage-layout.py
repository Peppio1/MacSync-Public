#!/usr/bin/env python3
"""Storage-layout experiment only. Never open an application database.
Synthetic SQLite fixtures compare the existing logical layout with an
inventory-integrated layout; no production reader/writer or delete authority.
"""
import json
import sqlite3
import tempfile
import time
from pathlib import Path
from statistics import median

COMMON = """
CREATE TABLE source_lineage_mapping(id INTEGER PRIMARY KEY, root_id TEXT NOT NULL,
 source_binding TEXT NOT NULL, target_binding TEXT NOT NULL,
 UNIQUE(root_id,source_binding,target_binding));
INSERT INTO source_lineage_mapping VALUES(1,'photos','source','target');
CREATE TABLE source_lineage_hold(mapping_id INTEGER NOT NULL, identity BLOB NOT NULL,
 protected_path TEXT NOT NULL, reason INTEGER NOT NULL CHECK(reason IN (0,1)),
 PRIMARY KEY(mapping_id,identity,protected_path)) WITHOUT ROWID;
CREATE INDEX idx_lineage_hold_path ON source_lineage_hold(mapping_id,protected_path);
CREATE TABLE source_lineage_invalid_observation(mapping_id INTEGER NOT NULL,path TEXT NOT NULL,
 identity BLOB NOT NULL CHECK(length(identity)=33),PRIMARY KEY(mapping_id,path)) WITHOUT ROWID;
"""
INV = """CREATE TABLE file_inventory(root_id TEXT NOT NULL,relative_path TEXT NOT NULL,
 kind TEXT NOT NULL,file_size INTEGER NOT NULL,modified_at REAL NOT NULL,change_stamp TEXT,
 {extra} PRIMARY KEY(root_id,relative_path));"""
OLD = """CREATE TABLE source_lineage_index(mapping_id INTEGER NOT NULL,
 identity BLOB NOT NULL CHECK(length(identity)=33),current_path TEXT NOT NULL,
 revision INTEGER NOT NULL CHECK(revision>0),evidence INTEGER NOT NULL CHECK(evidence BETWEEN 0 AND 2),
 uncertain INTEGER NOT NULL CHECK(uncertain IN (0,1)),recognized_paths BLOB,
 PRIMARY KEY(mapping_id,identity)) WITHOUT ROWID;
 CREATE INDEX idx_lineage_current_path ON source_lineage_index(mapping_id,current_path);"""
NEW = """CREATE UNIQUE INDEX live_lineage_identity ON file_inventory(mapping_id,identity)
 WHERE identity IS NOT NULL;
 CREATE TABLE lineage_detached(mapping_id INTEGER NOT NULL,identity BLOB NOT NULL CHECK(length(identity)=33),
 current_path TEXT NOT NULL,revision INTEGER NOT NULL CHECK(revision>0),
 evidence INTEGER NOT NULL CHECK(evidence BETWEEN 0 AND 2),uncertain INTEGER NOT NULL CHECK(uncertain IN (0,1)),
 PRIMARY KEY(mapping_id,identity)) WITHOUT ROWID;
 CREATE INDEX detached_path ON lineage_detached(mapping_id,current_path);
 CREATE TABLE lineage_exception(mapping_id INTEGER NOT NULL,identity BLOB NOT NULL CHECK(length(identity)=33),
 recognized_paths BLOB NOT NULL,PRIMARY KEY(mapping_id,identity)) WITHOUT ROWID;"""
EXTRA = """mapping_id INTEGER,identity BLOB CHECK(identity IS NULL OR length(identity)=33),
 revision INTEGER CHECK(revision>0),evidence INTEGER CHECK(evidence BETWEEN 0 AND 2),
 uncertain INTEGER CHECK(uncertain IN (0,1)),
 CHECK((identity IS NULL AND mapping_id IS NULL AND revision IS NULL AND evidence IS NULL AND uncertain IS NULL)
 OR (identity IS NOT NULL AND mapping_id IS NOT NULL AND revision IS NOT NULL AND evidence IS NOT NULL AND uncertain IS NOT NULL)),"""

def identity(i, kind):
    return b"".join(n.to_bytes(8,"big") for n in (1,i+1,1700000000,1234)) + (b"\x01" if kind=="file" else b"\x02")

def encode(paths):
    return json.dumps(paths,ensure_ascii=False,separators=(",",":")).encode()

def clock(f):
    t=time.perf_counter()
    result=f()
    return result,time.perf_counter()-t

def open_db(path, integrated):
    db=sqlite3.connect(path)
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript(COMMON+INV.format(extra=EXTRA if integrated else "")+(NEW if integrated else OLD))
    return db

def size(db):
    return db.execute("PRAGMA page_count").fetchone()[0]*db.execute("PRAGMA page_size").fetchone()[0]

def fixture():
    rows=[]
    for i in range(1000):
        rows.append((f"folder-{i}","directory",0))
        for j in range(10):
            rows.append((f"folder-{i}/photo-{j}.jpg","file",64))
    return [(path,kind,n,identity(i,kind),f"{i+1}:1700000000:1234") for i,(path,kind,n) in enumerate(rows)]

def populate(db, integrated, rows):
    with db:
        if integrated:
            db.executemany("""INSERT INTO file_inventory VALUES('photos',?,?,?,1700000000,?,1,?,1,0,0)""",
                           [(p,k,n,stamp,ident) for p,k,n,ident,stamp in rows])
        else:
            db.executemany("INSERT INTO file_inventory VALUES('photos',?,?,?,1700000000,?)",
                           [(p,k,n,stamp) for p,k,n,ident,stamp in rows])
            db.executemany("INSERT INTO source_lineage_index VALUES(1,?,?,1,0,0,NULL)",
                           [(ident,p) for p,k,n,ident,stamp in rows])

def recognize_all(db, integrated, rows):
    with db:
        if integrated:
            db.executemany("""UPDATE file_inventory SET evidence=2,revision=2
                WHERE mapping_id=1 AND identity=? AND relative_path=? AND revision=1""",
                [(ident,p) for p,k,n,ident,stamp in rows])
        else:
            db.executemany("""UPDATE source_lineage_index SET evidence=2,revision=2,recognized_paths=?
                WHERE mapping_id=1 AND identity=? AND current_path=? AND revision=1""",
                [(encode([p]),ident,p) for p,k,n,ident,stamp in rows])

def read(db, integrated, ident):
    if integrated:
        live=db.execute("""SELECT f.relative_path,f.revision,f.evidence,f.uncertain,e.recognized_paths,
             EXISTS(SELECT 1 FROM source_lineage_hold h WHERE h.mapping_id=f.mapping_id AND h.identity=f.identity)
             FROM file_inventory f LEFT JOIN lineage_exception e ON e.mapping_id=f.mapping_id AND e.identity=f.identity
             WHERE f.mapping_id=1 AND f.identity=?""",(ident,)).fetchone()
        if live is None:
            live=db.execute("""SELECT d.current_path,d.revision,d.evidence,d.uncertain,e.recognized_paths,
                EXISTS(SELECT 1 FROM source_lineage_hold h WHERE h.mapping_id=d.mapping_id AND h.identity=d.identity)
                FROM lineage_detached d LEFT JOIN lineage_exception e ON e.mapping_id=d.mapping_id AND e.identity=d.identity
                WHERE d.mapping_id=1 AND d.identity=?""",(ident,)).fetchone()
    else:
        live=db.execute("""SELECT i.current_path,i.revision,i.evidence,i.uncertain,i.recognized_paths,
             EXISTS(SELECT 1 FROM source_lineage_hold h WHERE h.mapping_id=i.mapping_id AND h.identity=i.identity)
             FROM source_lineage_index i WHERE i.mapping_id=1 AND i.identity=?""",(ident,)).fetchone()
    if live is None:
        return None
    p,rev,ev,unc,blob,hold=live
    paths=json.loads(blob) if blob is not None else ([p] if integrated and ev==2 else [])
    assert ev!=2 or paths
    assert ev!=1 or (not paths and not unc)
    return p,rev,ev,unc,paths,hold

def detach(db, integrated, ident, path):
    # Prototype: old path disappears before the new path is observed.
    # Preserve the recognized path and hold in the SAME transaction.
    with db:
        if integrated:
            db.execute("""INSERT INTO lineage_detached SELECT mapping_id,identity,relative_path,
                    revision,evidence,uncertain FROM file_inventory
                    WHERE mapping_id=1 AND identity=? AND relative_path=?""",(ident,path))
        db.execute("INSERT INTO source_lineage_hold VALUES(1,?,?,0)",(ident,path))
        db.execute("DELETE FROM file_inventory WHERE root_id='photos' AND relative_path=?",(path,))

def reattach(db, integrated, ident, old, new, kind, n, stamp, rev):
    # Explicit transaction preserves exception + hold until actual
    # production publication/alias validation, which this model never grants.
    with db:
        record=read(db,integrated,ident)
        if record is None or record[0]!=old or record[1]!=rev:
            raise ValueError("stale revision or path")
        paths=record[4]
        if integrated:
            if db.execute("SELECT 1 FROM lineage_detached WHERE mapping_id=1 AND identity=?",(ident,)).fetchone() is None:
                raise ValueError("not detached")
            db.execute("INSERT INTO file_inventory VALUES('photos',?,?,?,1700000000,?,1,?,?,?,?)",
                       (new,kind,n,stamp,ident,rev+1,record[2],record[3]))
            if paths and paths!=[new]:
                db.execute("INSERT OR REPLACE INTO lineage_exception VALUES(1,?,?)",(ident,encode(paths)))
            db.execute("DELETE FROM lineage_detached WHERE mapping_id=1 AND identity=?",(ident,))
        else:
            db.execute("INSERT INTO file_inventory VALUES('photos',?,?,?,1700000000,?)",(new,kind,n,stamp))
            db.execute("UPDATE source_lineage_index SET current_path=?,revision=? WHERE mapping_id=1 AND identity=?",
                       (new,rev+1,ident))
        db.execute("UPDATE source_lineage_hold SET reason=1 WHERE mapping_id=1 AND identity=?",(ident,))

def test():
    rows=fixture()
    with tempfile.TemporaryDirectory(prefix="macsync-layout-") as tmp:
        paths=[Path(tmp)/"separate.sqlite",Path(tmp)/"integrated.sqlite"]
        dbs=[open_db(paths[0],False),open_db(paths[1],True)]
        seed=[]; first=[]; reads=[[],[]]
        for mode,db in enumerate(dbs):
            seed.append(clock(lambda:populate(db,mode,rows))[1])
            assert read(db,mode,rows[0][3])[2:5]==(0,0,[])
            first.append(clock(lambda:recognize_all(db,mode,rows))[1])
        sizes=[size(db) for db in dbs]
        for i in range(4):
            for mode in ([0,1] if i%2==0 else [1,0]):
                result,elapsed=clock(lambda:[read(dbs[mode],mode,r[3]) for r in rows])
                reads[mode].append(elapsed)
                assert all(x==(r[0],2,2,0,[r[0]],0) for x,r in zip(result,rows))
        print("LAYOUT_STORAGE",json.dumps(dict(entries=len(rows),separate_bytes=sizes[0],integrated_bytes=sizes[1],
              seed_seconds=seed,recognition_seconds=first,lookup_median_seconds=[median(x) for x in reads])))
        assert dbs[1].execute("SELECT COUNT(*) FROM lineage_exception").fetchone()[0]==0
        # Simulate both a directory and files, separated old/new events,
        # exact UTF-8 paths, reopen, conflict and stale revision rollback.
        selected=[rows[0],rows[1],rows[12],rows[23]]
        for mode,db in enumerate(dbs):
            for p,k,n,ident,stamp in selected:
                detach(db,mode,ident,p)
                assert read(db,mode,ident)==(p,2,2,0,[p],1)
            db.close()
            dbs[mode]=sqlite3.connect(paths[mode])
        for mode,db in enumerate(dbs):
            for p,k,n,ident,stamp in selected:
                assert read(db,mode,ident)==(p,2,2,0,[p],1)
                try:
                    reattach(db,mode,ident,p,rows[-1][0],k,n,stamp,2)
                    raise AssertionError("occupied path accepted")
                except sqlite3.IntegrityError:
                    pass
                assert read(db,mode,ident)==(p,2,2,0,[p],1)
                try:
                    reattach(db,mode,ident,p,p+" ",k,n,stamp,1)
                    raise AssertionError("stale revision accepted")
                except ValueError:
                    pass
                reattach(db,mode,ident,p,p+" ",k,n,stamp,2)
                assert read(db,mode,ident)==(p+" ",3,2,0,[p],1)
            # Replace a deleted spelling with an unrelated new identity:
            # no old evidence or hold may transfer to the new object.
            p,k,n,ident,stamp=selected[1]
            new_id=identity(999999,k)
            with db:
                if mode:
                    db.execute("INSERT INTO file_inventory VALUES('photos',?,?,?,1700000000,?,1,?,1,0,0)",
                               (p,k,n,"999999:1700000000:1234",new_id))
                else:
                    db.execute("INSERT INTO file_inventory VALUES('photos',?,?,?,1700000000,?)",(p,k,n,"999999:1700000000:1234"))
                    db.execute("INSERT INTO source_lineage_index VALUES(1,?,?,1,0,0,NULL)",(new_id,p))
            assert read(db,mode,new_id)==(p,1,0,0,[],0)
            assert read(db,mode,ident)==(p+" ",3,2,0,[p],1)
        for r in rows:
            assert read(dbs[0],False,r[3])==read(dbs[1],True,r[3])
        assert dbs[1].execute("SELECT COUNT(*) FROM lineage_exception").fetchone()[0]==len(selected)
        assert dbs[1].execute("SELECT COUNT(*) FROM lineage_detached").fetchone()[0]==0
        for db in dbs:
            assert db.execute("PRAGMA integrity_check").fetchone()[0]=="ok"
            db.close()
        print("LAYOUT_TRANSITIONS passed: unknown, matching, detached/reopen, collision, stale, rename, path reuse, parity, integrity")
if __name__=="__main__":
    test()
