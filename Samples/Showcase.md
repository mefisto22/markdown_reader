# Markdown Reader – bemutató

Árvíztűrő tükörfúrógép. **Félkövér**, *dőlt*, ***mindkettő***, ~~áthúzott~~ és `inline kód`.
Linkek: [másik dokumentum](Second.md), [szakasz](#táblázatok), https://example.com és <info@example.com>.

> Idézet több sorban, *kiemeléssel*.
>
> > Beágyazott idézet.

## Listák

- Első elem
- Második elem
  - Beágyazott elem
    - Még mélyebben
- Harmadik elem

1. Egy
2. Kettő
3. Három

- [x] Kész feladat
- [ ] Nyitott feladat

## Táblázatok

| Név | Mennyiség | Ár (Ft) |
|:----|:---------:|--------:|
| Őszibarack | 3 | 1 290 |
| Ütőfúró | 1 | 24 990 |
| Kék **tinta** | 12 | 450 |

## Kód

```swift
struct Greeter {
    func greet(_ name: String) -> String {
        "Szia, \(name)!"
    }
}
```

    indented code block

---

## Kép

![Helyi kép](images/diagram.png)

![Távoli kép](https://example.com/remote.png)

<p align="center"><b>HTML</b> bekezdés <kbd>⌘</kbd> + <kbd>S</kbd><br>második sor</p>

<script>alert("never runs")</script>

### Harmadik szintű cím

Hard break a sor végén  
új sor. Lábjegyzet-szerű [hivatkozás][ref].

[ref]: https://daringfireball.net/projects/markdown/
