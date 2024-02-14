use alexandria_data_structures::array_ext::ArrayTraitExt;
use core::debug::PrintTrait;
use alexandria_data_structures::array_ext::SpanTraitExt;
use core::option::OptionTrait;
use core::traits::Into;
use core::traits::TryInto;
use core::array::SpanTrait;
use core::clone::Clone;
use core::dict::Felt252DictEntryTrait;
use core::nullable::{nullable_from_box, match_nullable, FromNullableResult};
use core::array::ArrayTrait;
use core::zeroable::Zeroable;

use alexandria_data_structures::byte_array_ext::{ByteArrayIntoArrayU8, SpanU8IntoBytearray};

use quadtree::area::{AreaTrait, Area, AreaImpl};
use quadtree::point::{Point, PointTrait, PointImpl};
use quadtree::{QuadtreeTrait, QuadtreeNode, QuadtreeNodeTrait};

/// All the branches and leaves of the quadtree are stored in a dictionary.
struct Felt252Quadtree<T, P, C> {
    elements: Felt252Dict<Nullable<QuadtreeNode<T, P, C>>>,
    spillover_threhold: usize
}


impl Felt252QuadtreeImpl<
    T,
    P,
    C,
    +Copy<T>,
    +Copy<C>,
    +Copy<P>,
    +Drop<T>,
    +Drop<C>,
    +Drop<P>,
    +Into<P, felt252>, // Dict key is felt252
    +Into<u8, P>, // Adding nested level
    +Add<P>, // Nesting the path
    +Mul<P>, // Nesting the path
    +Sub<P>, // QuadtreeNodeTrait
    +PointTrait<C>, // Present in the area
    +AreaTrait<C>,
    +PartialEq<C>,
    +PartialOrd<C>,
    +PartialOrd<P>,
    +PartialEq<T>,
    +PartialEq<P>,
> of QuadtreeTrait<T, P, C> {
    fn new(region: Area<C>, spillover_threhold: usize) -> Felt252Quadtree<T, P, C> {
        // constructng the root node
        let root_path = 1_u8;
        let root = QuadtreeNodeTrait::new(region, 1_u8.into());

        // creating the dictionary
        let elements = Default::default();
        let mut tree = Felt252Quadtree { elements, spillover_threhold };

        // inserting it at root
        tree.elements.insert(root_path.into(), nullable_from_box(BoxTrait::new(root)));
        tree
    }

    fn values(ref self: Felt252Quadtree<T, P, C>, path: P) -> Array<T> {
        // getting the node from the dictionary without cloning it
        let (entry, val) = self.elements.entry(path.into());
        let node = match match_nullable(val) {
            FromNullableResult::Null => panic!("Node does not exist"),
            FromNullableResult::NotNull(val) => val.unbox(),
        };

        // getting the values from the node
        let mut result = ArrayTrait::new();
        result.append_span(node.values);

        // returning the node to the dictionary
        let val = nullable_from_box(BoxTrait::new(node));
        self.elements = entry.finalize(val);
        result
    }

    fn points(ref self: Felt252Quadtree<T, P, C>, path: P) -> Array<Point<C>> {
        // getting the node from the dictionary without cloning it
        let (entry, val) = self.elements.entry(path.into());
        let node = match match_nullable(val) {
            FromNullableResult::Null => panic!("Node does not exist"),
            FromNullableResult::NotNull(val) => val.unbox(),
        };

        // getting the points from the node
        let mut result = ArrayTrait::new();
        result.append_span(node.members);

        // returning the node to the dictionary
        let val = nullable_from_box(BoxTrait::new(node));
        self.elements = entry.finalize(val);
        result
    }

    fn query_regions(ref self: Felt252Quadtree<T, P, C>, point: Point<C>) -> Array<T> {
        let mut path = Option::Some(1_u8.into());
        let mut values = ArrayTrait::new();

        loop {
            // get the node from the dictionary without cloning it
            let (entry, val) = match path {
                Option::Some(path) => self.elements.entry(path.into()),
                // break if the last node was a leaf
                Option::None => { break; },
            };
            let mut node = match match_nullable(val) {
                FromNullableResult::Null => panic!("Node does not exist"),
                FromNullableResult::NotNull(val) => val.unbox(),
            };

            // add the values to the result
            let mut i = 0;
            loop {
                if i == node.values.len() {
                    break;
                }
                values.append(*node.values[i]);
                i += 1;
            };

            // get the next node and return the current one to the dictionary
            path = node.child_at(@point);
            let val = nullable_from_box(BoxTrait::new(node));
            self.elements = entry.finalize(val);
        };

        values
    }

    fn closest_points(
        ref self: Felt252Quadtree<T, P, C>, point: Point<C>, n: usize
    ) -> Array<@Point<C>> {
        // loosely based on https://www.cs.umd.edu/%7Emeesh/cmsc420/ContentBook/FormalNotes/neighbor.pdf
        let mut to_visit = 1_u8.into();
        let mut passed = ArrayTrait::new();

        // first find all nodes on the path to leaf
        loop {
            passed.append(to_visit);

            // get the node from the dictionary without cloning it
            let (entry, val) = self.elements.entry(to_visit.into());
            let mut node = match match_nullable(val) {
                FromNullableResult::Null => panic!("Node does not exist"),
                FromNullableResult::NotNull(val) => val.unbox(),
            };

            to_visit = match node.child_at(@point) {
                Option::Some(path) => path,
                Option::None => {
                    let val = nullable_from_box(BoxTrait::new(node));
                    self.elements = entry.finalize(val);
                    break;
                }
            };

            let val = nullable_from_box(BoxTrait::new(node));
            self.elements = entry.finalize(val);
        };

        let mut to_check = ArrayTrait::new();
        let mut found = ArrayTrait::new();
        let mut confirmed_closest = ArrayTrait::new();
        let mut already_checked = ArrayTrait::new();
        loop {
            // calculate pessimistic distance to all the nodes
            loop {
                match passed.pop_front() {
                    Option::Some(path) => {
                        // process only if it was not processed before
                        match already_checked.contains(path) {
                            true => { continue; },
                            false => { already_checked.append(path); },
                        }

                        let (entry, val) = self.elements.entry(path.into());
                        let node = match match_nullable(val) {
                            FromNullableResult::Null => panic!("Node does not exist"),
                            FromNullableResult::NotNull(val) => val.unbox(),
                        };

                        // calculate the maximux distance from the point to the member of the node
                        let distance = node.region.distance_at_most(@point);
                        to_check.append((distance, node.path));

                        let val = nullable_from_box(BoxTrait::new(node));
                        self.elements = entry.finalize(val);
                    },
                    Option::None => { break; },
                }
            };

            // get the closest node
            let (dist, path) = match remove_min(ref to_check) {
                Option::Some((d, v)) => (*d, *v),
                Option::None => { break; },
            };
            let (entry, val) = self.elements.entry(path.into());
            let node = match match_nullable(val) {
                FromNullableResult::Null => panic!("Node does not exist"),
                FromNullableResult::NotNull(val) => val.unbox(),
            };

            // check if the node is a leaf or not
            match node.split.is_some() {
                true => passed.append_span(node.children_paths().span()),
                false => {
                    let mut members = node.members;
                    loop {
                        match members.pop_front() {
                            Option::Some(member) => {
                                found.append((member.distance_squared(@point), member));
                            },
                            Option::None => { break; },
                        }
                    }
                },
            };

            loop {
                match remove_min(ref found) {
                    Option::Some((d, p)) => match *d <= dist {
                        true => confirmed_closest.append(*p),
                        false => found.append((*d, *p)),
                    },
                    Option::None => { break; },
                }
            };

            let val = nullable_from_box(BoxTrait::new(node));
            self.elements = entry.finalize(val);

            if confirmed_closest.len() >= n {
                break;
            }
        };

        confirmed_closest
    }

    fn insert_point(ref self: Felt252Quadtree<T, P, C>, point: Point<C>) {
        let mut path: P = 1_u8.into();

        loop {
            // get the node from the dictionary without cloning it
            let (entry, val) = self.elements.entry(path.into());
            let mut node = match match_nullable(val) {
                FromNullableResult::Null => panic!("Node does not exist"),
                FromNullableResult::NotNull(val) => val.unbox(),
            };

            // get the next node and return the current one to the dictionary
            path = match node.child_at(@point) {
                Option::Some(path) => path,
                Option::None => {
                    // adding the value if the node is a leaf
                    let mut new = ArrayTrait::new();
                    new.append_span(node.members);
                    new.append(point);
                    node.members = new.span();

                    let did_spill = match node.members.len() > self.spillover_threhold {
                        true => match new
                            .span()
                            .dedup()
                            .len() >= 2 { // if has at least 2 unique points
                            true => Option::Some(node.region.center()),
                            false => Option::None,
                        },
                        false => Option::None,
                    };

                    let val = nullable_from_box(BoxTrait::new(node));
                    self.elements = entry.finalize(val);

                    // splitting the node if it has too many points
                    if did_spill.is_some() {
                        self.split(path, did_spill.unwrap());
                    }

                    break;
                }
            };

            let val = nullable_from_box(BoxTrait::new(node));
            self.elements = entry.finalize(val);
        };
    }

    fn remove_point(ref self: Felt252Quadtree<T, P, C>, point: Point<C>) -> Option<Point<C>> {
        let mut path: P = 1_u8.into();

        loop {
            // get the node from the dictionary without cloning it
            let (entry, val) = self.elements.entry(path.into());
            let mut node = match match_nullable(val) {
                FromNullableResult::Null => panic!("Node does not exist"),
                FromNullableResult::NotNull(val) => val.unbox(),
            };

            // get the next node or process leaf
            path = match node.child_at(@point) {
                Option::Some(path) => path,
                Option::None => {
                    // searching for the point in the node
                    let mut new = ArrayTrait::new();
                    let found = loop {
                        match node.members.pop_front() {
                            Option::Some(member) => {
                                if *member == point {
                                    // do not add the removed point back to the node
                                    break Option::Some(*member);
                                }
                                new.append(*member);
                            },
                            Option::None => { break Option::None; },
                        }
                    };
                    // adding the remaining points to the node
                    new.append_span(node.members);
                    node.members = new.span();

                    let val = nullable_from_box(BoxTrait::new(node));
                    self.elements = entry.finalize(val);

                    break found;
                }
            };

            // return the current node to the dictionary
            let val = nullable_from_box(BoxTrait::new(node));
            self.elements = entry.finalize(val);
        }
    }


    fn insert_region(ref self: Felt252Quadtree<T, P, C>, value: T, region: Area<C>) {
        let mut to_visit = array![1_u8.into()];
        let mut split = Option::None;

        loop {
            // getting a smaller node
            let path = match to_visit.pop_front() {
                Option::Some(path) => path,
                Option::None => { break; },
            };
            let (entry, val) = self.elements.entry(path.into());
            let mut node = match match_nullable(val) {
                FromNullableResult::Null => panic!("Node does not exist"),
                FromNullableResult::NotNull(val) => val.unbox(),
            };

            if !region
                .intersects(
                    @node.region
                ) { // if the region does not intersect the node's region, we skip it
            } else if region.contains(node.region.bottom_right())
                && region.contains(node.region.top_left()) {
                // if the region contains the node, we add it to the node
                let mut new = ArrayTrait::new();
                new.append_span(node.values);
                new.append(value);
                node.values = new.span();
            } else if node.split.is_none() {
                // if the node is a leaf, and not all in the region it needs to be split, and then visited again
                split = Option::Some(node.region.center());
                to_visit.append(path);
            } else {
                // if the region does not contain the node, we check its children
                to_visit.append_span(node.children_paths().span());
            }

            let val = nullable_from_box(BoxTrait::new(node));
            self.elements = entry.finalize(val);

            match split {
                Option::Some(center) => {
                    self.split(path, center);
                    split = Option::None;
                },
                Option::None => {},
            }
        };
    }

    fn remove_region(ref self: Felt252Quadtree<T, P, C>, value: T, region: Area<C>) -> bool {
        let mut to_visit = array![1_u8.into()];
        let mut did_remove = false;

        loop {
            // getting a smaller node
            let path = match to_visit.pop_front() {
                Option::Some(path) => path,
                Option::None => { break; },
            };
            let (entry, val) = self.elements.entry(path.into());
            let mut node = match match_nullable(val) {
                FromNullableResult::Null => panic!("Node does not exist"),
                FromNullableResult::NotNull(val) => val.unbox(),
            };

            if !region
                .intersects(
                    @node.region
                ) { // if the region does not intersect the node's region, we skip it
            } else if region.contains(node.region.bottom_right())
                && region.contains(node.region.top_left()) {
                // if the region contains the node, we add it to the node
                let mut new = ArrayTrait::new();
                let found = loop {
                    match node.values.pop_front() {
                        Option::Some(current) => {
                            if *current == value {
                                // do not add the removed point back to the node
                                break true;
                            }
                            new.append(*current);
                        },
                        Option::None => { break false; },
                    }
                };
                // adding the remaining points to the node
                new.append_span(node.values);
                node.values = new.span();
                did_remove = did_remove || found;
            } else if node.split.is_none() {
                // if the node is a leaf, and not all in the region it needs to be split, and then visited again
                to_visit.append(path);
                panic(
                    array![
                        'not a valid operation ', ', abording to avoid ', 'persisting invalid state'
                    ]
                );
            } else {
                // if the region does not contain the node, we check its children
                let child_path = node.path * 4_u8.into();
                to_visit.append(child_path);
                to_visit.append(child_path + 1_u8.into());
                to_visit.append(child_path + 2_u8.into());
                to_visit.append(child_path + 3_u8.into());
            }

            let val = nullable_from_box(BoxTrait::new(node));
            self.elements = entry.finalize(val);
        };

        did_remove
    }


    fn split(ref self: Felt252Quadtree<T, P, C>, path: P, point: Point<C>) {
        if path > path * 4_u8.into() {
            // tree reached its maximum depth
            return;
        }

        // getting the node from the dictionary without cloning it
        let (entry, val) = self.elements.entry(path.into());
        let mut parent = match match_nullable(val) {
            FromNullableResult::Null => panic!("Node does not exist"),
            FromNullableResult::NotNull(val) => val.unbox(),
        };

        let mut children = parent.split_at(point);

        // returning the node to the dictionary
        let val = nullable_from_box(BoxTrait::new(parent));
        self.elements = entry.finalize(val);

        loop {
            match children.pop_front() {
                Option::Some(child) => {
                    let path = child.path.into();
                    let child = nullable_from_box(BoxTrait::new(child));
                    self.elements.insert(path, child);
                },
                Option::None => { break; },
            };
        };
    }

    fn exists(ref self: Felt252Quadtree<T, P, C>, path: P) -> bool {
        let (entry, val) = self.elements.entry(path.into());
        let exists = !val.is_null();
        self.elements = entry.finalize(val);
        exists
    }
}

// Needed as array doesn't implement Drop nor Destruct
impl DestructFelt252Quadtree<
    T, P, C, +Drop<T>, +Drop<C>, +Drop<P>
> of Destruct<Felt252Quadtree<T, P, C>> {
    fn destruct(self: Felt252Quadtree<T, P, C>) nopanic {
        self.elements.squash();
    }
}

fn remove_min<T, U, +Copy<T>, +Drop<T>, +Copy<U>, +Drop<U>, +PartialEq<T>, +PartialOrd<T>>(
    ref arr: Array<(T, U)>
) -> Option<(@T, @U)> {
    let mut index = 1;
    let mut index_of_min = 0;
    let mut looking_for_min = arr.span();
    let (mut min_d, mut min_v) = match looking_for_min.pop_front() {
        Option::Some(item) => item,
        Option::None => { return Option::None; },
    };

    loop {
        match looking_for_min.pop_front() {
            Option::Some((
                d, v
            )) => { if *d < *min_d {
                index_of_min = index;
                min_d = d;
                min_v = v;
            } },
            Option::None => { break; },
        };
        index += 1;
    };

    // let end = arr.len() - 1_usize;
    let end = arr.len() - index_of_min - 1;
    let left = arr.span().slice(0, index_of_min);
    let right = arr.span().slice(index_of_min + 1_usize, end);

    arr = ArrayTrait::new();
    arr.append_span(left);
    arr.append_span(right);

    Option::Some((min_d, min_v))
}

#[test]
fn test_remove_min() {
    let mut a = array![(3_u8, ()), (1, ()), (2, ())];
    let (b, _) = remove_min(ref a).unwrap();

    assert(*b == 1, 'invalid first min');
    assert(a.len() == 2, 'invalid first len');

    let (b, _) = remove_min(ref a).unwrap();
    assert(*b == 2, 'invalid second min');
    assert(a.len() == 1, 'invalid second len');

    let (b, _) = remove_min(ref a).unwrap();
    assert(*b == 3, 'invalid third min');
    assert(a.len() == 0, 'invalid third len');
}
